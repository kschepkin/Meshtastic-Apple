//
//  ScreenIntervals.swift
//  Meshtastic
//
//  Copyright(c) Garth Vander Houwen 8/20/22.
//

import Foundation
import MeshtasticProtobufs

enum ScreenUnits: Int, CaseIterable, Identifiable {

	case metric = 0
	case imperial = 1

    var id: Int { self.rawValue }
	var description: String {
		switch self {
		case .metric:
		   return "Metric"
		case .imperial:
		   return "Imperial"
		}
	}
	func protoEnumValue() -> Config.DisplayConfig.DisplayUnits {

		switch self {
		case .metric:
			return Config.DisplayConfig.DisplayUnits.metric
		case .imperial:
			return Config.DisplayConfig.DisplayUnits.imperial
		}
	}
}

enum ScreenOnIntervals: Int, CaseIterable, Identifiable {

	case fifteenSeconds = 15
	case thirtySeconds = 30
	case oneMinute = 60
	case fiveMinutes = 300
	case tenMinutes = 600
	case fifteenMinutes = 900
	case thirtyMinutes = 1800
	case oneHour = 3600
	case max = 31536000 // One Year

	var id: Int { self.rawValue }
	var description: String {
		switch self {
		case .fifteenSeconds:
			return "Fifteen Seconds".localized
		case .thirtySeconds:
			return "Thirty Seconds".localized
		case .oneMinute:
			return "One Minute".localized
		case .fiveMinutes:
			return "Five Minutes".localized
		case .tenMinutes:
			return "Ten Minutes".localized
		case .fifteenMinutes:
			return "Fifteen Minutes".localized
		case .thirtyMinutes:
			return "Thirty Minutes".localized
		case .oneHour:
			return "One Hour".localized
		case .max:
			return "Always On".localized
		}
	}
}

// Default of 0 is off
enum ScreenCarouselIntervals: Int, CaseIterable, Identifiable {

	case off = 0
	case fifteenSeconds = 15
	case thirtySeconds = 30
	case oneMinute = 60
	case fiveMinutes = 300
	case tenMinutes = 600
	case fifteenMinutes = 900

	var id: Int { self.rawValue }
	var description: String {
		switch self {
		case .off:
			return "off".localized.capitalized
		case .fifteenSeconds:
			return "Fifteen Seconds".localized
		case .thirtySeconds:
			return "Thirty Seconds".localized
		case .oneMinute:
			return "One Minute".localized
		case .fiveMinutes:
			return "Five Minutes".localized
		case .tenMinutes:
			return "Ten Minutes".localized
		case .fifteenMinutes:
			return "Fifteen Minutes".localized
		}
	}
}
// Default of 0 is auto
enum OledTypes: Int, CaseIterable, Identifiable {

	case auto = 0
	case ssd1306 = 1
	case sh1106 = 2
	case sh1107 = 3

	var id: Int { self.rawValue }
	var description: String {
		switch self {
		case .auto:
			return "Detect Automatically".localized
		case .ssd1306:
			return "SSD 1306"
		case .sh1106:
			return "SH 1106"
		case .sh1107:
			return "SH 1107"
		}
	}
	func protoEnumValue() -> Config.DisplayConfig.OledType {

		switch self {
		case .auto:
			return Config.DisplayConfig.OledType.oledAuto
		case .ssd1306:
			return Config.DisplayConfig.OledType.oledSsd1306
		case .sh1106:
			return Config.DisplayConfig.OledType.oledSh1106
		case .sh1107:
			return Config.DisplayConfig.OledType.oledSh1107
		}
	}
}

// Default of 0 is auto
enum DisplayModes: Int, CaseIterable, Identifiable {

	case defaultMode = 0
	case twoColor = 1
	case inverted = 2
	case color = 3

	var id: Int { self.rawValue }
	var description: String {
		switch self {
		case .defaultMode:
			return "Default 128x64 screen layout".localized
		case .twoColor:
			return "Optimized for 2 color displays".localized
		case .inverted:
			return "Inverted top bar for 2 Color display".localized
		case .color:
			return "TFT Full Color Displays".localized
		}
	}
	func protoEnumValue() -> Config.DisplayConfig.DisplayMode {

		switch self {
		case .defaultMode:
			return Config.DisplayConfig.DisplayMode.default
		case .twoColor:
			return Config.DisplayConfig.DisplayMode.twocolor
		case .inverted:
			return Config.DisplayConfig.DisplayMode.inverted
		case .color:
			return Config.DisplayConfig.DisplayMode.color
		}
	}
}

// Default of 0 is metric
enum Units: Int, CaseIterable, Identifiable {

	case metric = 0
	case imperial = 1

	var id: Int { self.rawValue }
	var description: String {
		switch self {
		case .metric:
			return "Metric"
		case .imperial:
			return "Imperial"
		}
	}
	func protoEnumValue() -> Config.DisplayConfig.DisplayUnits {

		switch self {
		case .metric:
			return Config.DisplayConfig.DisplayUnits.metric
		case .imperial:
			return Config.DisplayConfig.DisplayUnits.imperial
		}
	}
}
