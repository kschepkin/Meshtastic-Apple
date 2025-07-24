//
//  GpsFormats.swift
//  Meshtastic
//
//  Copyright(c) Garth Vander Houwen 8/20/22.
//

import Foundation
import MeshtasticProtobufs

enum GpsUpdateIntervals: Int, CaseIterable, Identifiable {

	case thirtySeconds = 30
	case oneMinute = 60
	case twoMinutes = 120
	case fiveMinutes = 300
	case tenMinutes = 600
	case fifteenMinutes = 900
	case thirtyMinutes = 1800
	case oneHour = 3600
	case sixHours = 21600
	case twelveHours = 43200
	case twentyFourHours = 86400
	case maxInt32 = 2147483647

	var id: Int { self.rawValue }
	var description: String {
		switch self {
		case .thirtySeconds:
			return "Thirty Seconds".localized
		case .oneMinute:
			return "One Minute".localized
		case .twoMinutes:
			return "Two Minutes".localized
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
		case .sixHours:
			return "Six Hours".localized
		case .twelveHours:
			return "Twelve Hours".localized
		case .twentyFourHours:
			return "Twenty Four Hours".localized
		case .maxInt32:
			return "On Boot Only".localized
		}
	}
}

enum GpsMode: Int, CaseIterable, Equatable {
	case enabled = 1
	case disabled = 0
	case notPresent = 2

	var id: Int { self.rawValue }

	var description: String {
		switch self {
		case .disabled:
			return "Disabled".localized
		case .enabled:
			return "Enabled".localized
		case .notPresent:
			return "Not Present".localized
		}
	}
	func protoEnumValue() -> Config.PositionConfig.GpsMode {

		switch self {

		case .enabled:
			return Config.PositionConfig.GpsMode.enabled
		case .disabled:
			return Config.PositionConfig.GpsMode.disabled
		case .notPresent:
			return Config.PositionConfig.GpsMode.notPresent
		}
	}
}
