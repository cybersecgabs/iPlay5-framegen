#include <metal_stdlib>
using namespace metal;

// Must match RenderUniforms in MetalRenderer.swift
struct RenderUniforms {
	float2 ndcScale;   // size of the picture quad in NDC (1,1 = full target)
	float2 uvOrigin;   // texture-space crop (zoom mode)
	float2 uvSize;
	float2 lumaSize;   // luma texture size in texels
	int matrix;        // 0 = BT.709, 1 = BT.2020
	int transferMode;  // 0 = passthrough, 1 = SDR on PQ target, 2 = PQ on SDR target
	int bicubic;       // Catmull-Rom luma upscaling
	int fullRange;
	float brightness;
	float contrast;
	float saturation;
	float gamma;
	int colorAdjust;   // 0 = bypass, 1 = apply color adjustments
	float sharpness;   // 0.0 ... 1.0 CAS sharpening
};

struct VertexOut {
	float4 position [[position]];
	float2 uv;
};

vertex VertexOut stream_vertex(uint vid [[vertex_id]], constant RenderUniforms &u [[buffer(0)]]) {
	// triangle strip quad
	float2 corner = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? -1.0 : 1.0);
	float2 uv01 = float2((vid & 1) ? 1.0 : 0.0, (vid & 2) ? 1.0 : 0.0);
	VertexOut out;
	out.position = float4(corner * u.ndcScale, 0.0, 1.0);
	out.uv = u.uvOrigin + uv01 * u.uvSize;
	return out;
}

// 9-tap Catmull-Rom using bilinear filtering (sharper than bilinear for the
// 1080p -> ~2670 px upscale on the Duo's inner screen).
static float sample_catmull_rom(texture2d<float> tex, sampler s, float2 uv, float2 texSize) {
	float2 samplePos = uv * texSize;
	float2 texPos1 = floor(samplePos - 0.5) + 0.5;
	float2 f = samplePos - texPos1;
	float2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
	float2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
	float2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
	float2 w3 = f * f * (-0.5 + 0.5 * f);
	float2 w12 = w1 + w2;
	float2 offset12 = w2 / w12;
	float2 tp0 = (texPos1 - 1.0) / texSize;
	float2 tp3 = (texPos1 + 2.0) / texSize;
	float2 tp12 = (texPos1 + offset12) / texSize;

	float r = 0.0;
	r += tex.sample(s, float2(tp0.x,  tp0.y)).r  * w0.x  * w0.y;
	r += tex.sample(s, float2(tp12.x, tp0.y)).r  * w12.x * w0.y;
	r += tex.sample(s, float2(tp3.x,  tp0.y)).r  * w3.x  * w0.y;
	r += tex.sample(s, float2(tp0.x,  tp12.y)).r * w0.x  * w12.y;
	r += tex.sample(s, float2(tp12.x, tp12.y)).r * w12.x * w12.y;
	r += tex.sample(s, float2(tp3.x,  tp12.y)).r * w3.x  * w12.y;
	r += tex.sample(s, float2(tp0.x,  tp3.y)).r  * w0.x  * w3.y;
	r += tex.sample(s, float2(tp12.x, tp3.y)).r  * w12.x * w3.y;
	r += tex.sample(s, float2(tp3.x,  tp3.y)).r  * w3.x  * w3.y;
	return r;
}

// SMPTE ST 2084 (PQ)
constant float PQ_M1 = 0.1593017578125;
constant float PQ_M2 = 78.84375;
constant float PQ_C1 = 0.8359375;
constant float PQ_C2 = 18.8515625;
constant float PQ_C3 = 18.6875;

static float3 pq_to_linear(float3 e) { // -> nits / 10000
	float3 p = pow(max(e, 0.0), 1.0 / PQ_M2);
	return pow(max(p - PQ_C1, 0.0) / (PQ_C2 - PQ_C3 * p), 1.0 / PQ_M1);
}

static float3 linear_to_pq(float3 l) { // l in nits / 10000
	float3 p = pow(max(l, 0.0), PQ_M1);
	return pow((PQ_C1 + PQ_C2 * p) / (1.0 + PQ_C3 * p), PQ_M2);
}

static float3 apply_color_adjustments(float3 rgb,
                                      float brightness,
                                      float contrast,
                                      float saturation,
                                      float gamma,
                                      int bt2020) {
	if (abs(gamma - 1.0) > 0.001) {
		rgb = pow(max(rgb, float3(0.0)), float3(1.0 / max(gamma, 0.1)));
	}
	rgb = saturate((rgb - 0.5) * contrast + 0.5 + brightness);
	if (abs(saturation - 1.0) > 0.001) {
		float3 weights = bt2020 ? float3(0.2627, 0.6780, 0.0593)
		                        : float3(0.2126, 0.7152, 0.0722);
		float luma = dot(rgb, weights);
		rgb = saturate(mix(float3(luma), rgb, saturation));
	}
	return rgb;
}

static float apply_cas_luma(texture2d<float> lumaTex, sampler s, float2 uv, float2 texSize, float centerY, float sharpness) {
	float2 texelStep = 1.0 / max(texSize, float2(1.0));
	float b = lumaTex.sample(s, uv + float2(0.0, -texelStep.y)).r;
	float d = lumaTex.sample(s, uv + float2(-texelStep.x, 0.0)).r;
	float f = lumaTex.sample(s, uv + float2(texelStep.x, 0.0)).r;
	float h = lumaTex.sample(s, uv + float2(0.0, texelStep.y)).r;

	float mn = min(min(min(b, d), min(f, h)), centerY);
	float mx = max(max(max(b, d), max(f, h)), centerY);

	float amp = sqrt(saturate(min(mn, 1.0 - mx) / max(mx, 1e-4)));
	float peak = -1.0 / mix(8.0, 5.0, sharpness);
	float w = amp * peak * sharpness;
	return saturate((centerY + (b + d + f + h) * w) / (1.0 + 4.0 * w));
}

static float3 apply_cas_rgb(texture2d<float> tex, sampler s, float2 uv, float2 texSize, float3 center, float sharpness) {
	float2 texelStep = 1.0 / max(texSize, float2(1.0));
	float3 b = saturate(tex.sample(s, uv + float2(0.0, -texelStep.y)).rgb);
	float3 d = saturate(tex.sample(s, uv + float2(-texelStep.x, 0.0)).rgb);
	float3 f = saturate(tex.sample(s, uv + float2(texelStep.x, 0.0)).rgb);
	float3 h = saturate(tex.sample(s, uv + float2(0.0, texelStep.y)).rgb);

	float3 mn = min(min(min(b, d), min(f, h)), center);
	float3 mx = max(max(max(b, d), max(f, h)), center);

	float3 amp = sqrt(saturate(min(mn, float3(1.0) - mx) / max(mx, float3(1e-4))));
	float peak = -1.0 / mix(8.0, 5.0, sharpness);
	float3 w = amp * peak * sharpness;
	return saturate((center + (b + d + f + h) * w) / (1.0 + 4.0 * w));
}

fragment float4 stream_fragment(VertexOut in [[stage_in]],
                                texture2d<float> lumaTex [[texture(0)]],
                                texture2d<float> chromaTex [[texture(1)]],
                                constant RenderUniforms &u [[buffer(0)]]) {
	constexpr sampler s(filter::linear, address::clamp_to_edge);

	float y = u.bicubic ? sample_catmull_rom(lumaTex, s, in.uv, u.lumaSize) : lumaTex.sample(s, in.uv).r;
	if (u.sharpness > 0.001) {
		y = apply_cas_luma(lumaTex, s, in.uv, u.lumaSize, y, u.sharpness);
	}
	float2 c = chromaTex.sample(s, in.uv).rg;

	if (!u.fullRange) {
		y = (y - 16.0 / 255.0) * (255.0 / 219.0);
		c = (c - 128.0 / 255.0) * (255.0 / 224.0);
	} else {
		c = c - 0.5;
	}

	float3 rgb;
	if (u.matrix == 1) { // BT.2020 non-constant luminance
		rgb = float3(y + 1.4746 * c.y,
		             y - 0.16455 * c.x - 0.57135 * c.y,
		             y + 1.8814 * c.x);
	} else {             // BT.709
		rgb = float3(y + 1.5748 * c.y,
		             y - 0.1873 * c.x - 0.4681 * c.y,
		             y + 1.8556 * c.x);
	}
	rgb = saturate(rgb);

	if (u.transferMode == 1) {
		if (u.colorAdjust != 0) {
			rgb = apply_color_adjustments(rgb, u.brightness, u.contrast, u.saturation, u.gamma, 0);
		}
		// SDR frame on an HDR (PQ) layer: BT.709 gamma -> linear -> BT.2020 -> PQ at 203 nits reference white
		float3 lin = pow(rgb, 2.4);
		const float3x3 bt709_to_2020 = float3x3(float3(0.6274, 0.0691, 0.0164),
		                                        float3(0.3293, 0.9195, 0.0880),
		                                        float3(0.0433, 0.0114, 0.8956));
		lin = bt709_to_2020 * lin;
		rgb = linear_to_pq(lin * (203.0 / 10000.0));
	} else if (u.transferMode == 2) {
		// PQ frame on an SDR layer: simple Reinhard tone map, no gamut mapping
		float3 nits = pq_to_linear(rgb) * 10000.0;
		float3 v = nits / 203.0;
		v = v / (1.0 + v * 0.25);
		rgb = pow(saturate(v), 1.0 / 2.4);
		if (u.colorAdjust != 0) {
			rgb = apply_color_adjustments(rgb, u.brightness, u.contrast, u.saturation, u.gamma, 0);
		}
	} else if (u.colorAdjust != 0) {
		rgb = apply_color_adjustments(rgb, u.brightness, u.contrast, u.saturation, u.gamma, u.matrix);
	}

	return float4(rgb, 1.0);
}

// Must match BlitUniforms in MetalRenderer.swift
struct BlitUniforms {
	float2 ndcScale;
	float2 uvOrigin;
	float2 uvSize;
	float2 texSize;
	int transferMode; // 0 = passthrough, 1 = SDR sRGB/BT.709 -> BT.2020 PQ
	int colorAdjust;  // 0 = bypass, 1 = apply color adjustments
	float brightness;
	float contrast;
	float saturation;
	float gamma;
	int bt2020;       // 0 = BT.709, 1 = BT.2020
	float sharpness;  // 0.0 ... 1.0 CAS sharpening
};

vertex VertexOut blit_vertex(uint vid [[vertex_id]], constant BlitUniforms &u [[buffer(0)]]) {
	float2 corner = float2((vid & 1) ? 1.0 : -1.0, (vid & 2) ? -1.0 : 1.0);
	float2 uv01 = float2((vid & 1) ? 1.0 : 0.0, (vid & 2) ? 1.0 : 0.0);
	VertexOut out;
	out.position = float4(corner * u.ndcScale, 0.0, 1.0);
	out.uv = u.uvOrigin + uv01 * u.uvSize;
	return out;
}

fragment float4 blit_fragment(VertexOut in [[stage_in]],
                              texture2d<float> srcTex [[texture(0)]],
                              constant BlitUniforms &u [[buffer(0)]]) {
	constexpr sampler s(filter::linear, address::clamp_to_edge);
	float3 rgb = saturate(srcTex.sample(s, in.uv).rgb);
	if (u.sharpness > 0.001) {
		rgb = apply_cas_rgb(srcTex, s, in.uv, u.texSize, rgb, u.sharpness);
	}
	if (u.colorAdjust != 0) {
		rgb = apply_color_adjustments(rgb, u.brightness, u.contrast, u.saturation, u.gamma, u.transferMode == 1 ? 0 : u.bt2020);
	}
	if (u.transferMode == 1) {
		float3 lin = pow(rgb, 2.4);
		const float3x3 bt709_to_2020 = float3x3(float3(0.6274, 0.0691, 0.0164),
		                                        float3(0.3293, 0.9195, 0.0880),
		                                        float3(0.0433, 0.0114, 0.8956));
		lin = bt709_to_2020 * lin;
		rgb = linear_to_pq(lin * (203.0 / 10000.0));
	}
	return float4(rgb, 1.0);
}

// Computes mean normalized luma difference across a 16x9 interior grid (0...1)
// to detect duplicated 30 fps frames inside a 60 fps Remote Play stream.
kernel void luma_diff_grid(texture2d<float, access::sample> prevLuma [[texture(0)]],
                           texture2d<float, access::sample> currLuma [[texture(1)]],
                           device float *outDiff [[buffer(0)]],
                           uint tid [[thread_position_in_grid]]) {
	if (tid != 0) {
		return;
	}
	constexpr sampler s(filter::linear, address::clamp_to_edge);
	float sum = 0.0;
	for (int gy = 0; gy < 9; ++gy) {
		float v = mix(0.06, 0.94, (float(gy) + 0.5) / 9.0);
		for (int gx = 0; gx < 16; ++gx) {
			float u = mix(0.06, 0.94, (float(gx) + 0.5) / 16.0);
			float2 uv = float2(u, v);
			float p = prevLuma.sample(s, uv).r;
			float c = currLuma.sample(s, uv).r;
			sum += abs(p - c);
		}
	}
	*outDiff = sum / 144.0;
}
