import UIKit

/// Works out whether we're on a foldable, and which of its screens we're on.
///
/// Both iPhone Duo screens are a similar shape (inner 951×669pt, outer 678×466pt,
/// both about 1.4:1), so they're told apart by size. The inner screen's short
/// side is far bigger than any normal iPhone's (440pt at most).
enum DeviceLayout {
	private static let innerScreenMinShortSide: CGFloat = 560
	/// Model identifiers of known foldables. Others are picked up the first time
	/// an inner-screen-sized window is seen.
	private static let knownFoldables: Set<String> = ["iPhone19,4"]
	private static let seenInnerScreenKey = "seenFoldableInnerScreen"

	static let modelIdentifier: String = {
		var info = utsname()
		uname(&info)
		return withUnsafeBytes(of: &info.machine) { raw in
			String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
		}
	}()

	static var isFoldable: Bool {
		knownFoldables.contains(modelIdentifier) || UserDefaults.standard.bool(forKey: seenInnerScreenKey)
	}

	static func isInnerScreen(_ size: CGSize) -> Bool {
		min(size.width, size.height) >= innerScreenMinShortSide
	}

	/// True on a foldable that's currently showing on its outer screen.
	static func isFolded(_ size: CGSize) -> Bool {
		isFoldable && !isInnerScreen(size)
	}

	static func noteWindowSize(_ size: CGSize) {
		if isInnerScreen(size), !UserDefaults.standard.bool(forKey: seenInnerScreenKey) {
			UserDefaults.standard.set(true, forKey: seenInnerScreenKey)
		}
	}
}
