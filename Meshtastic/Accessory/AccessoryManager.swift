//
//  AccessoryManager.swift
//  Created by Jake Bordens on 7/10/25.
//

import Foundation
import SwiftUI
import MeshtasticProtobufs
import OSLog
import CocoaMQTT

enum AccessoryError: Error {
	case discoveryFailed(String)
	case connectionFailed(String)
	case versionMismatch(String)
	case ioFailed(String)
	case appError(String)
	case timeout
	case disconnected
	case tooManyRetries
	
	var errorDescription: String? {
		switch self {
		case .discoveryFailed(let message):
			return "Discovery failed. \(message)"
		case .connectionFailed(let message):
			return "Connection failed. \(message)"
		case .versionMismatch(let message):
			return "Version mismatch: \(message)"
		case .ioFailed(let message):
			return "Communication failure: \(message)"
		case .appError(let message):
			return "Application error: \(message)"
		case .timeout:
			return "Timeout"
		case .disconnected:
			return "Disconnected"
		case .tooManyRetries:
			return "Too Many Retries"
		}
	}
}

enum AccessoryManagerState: Equatable {
	case uninitialized
	case idle
	case discovering
	case connecting
	case retrying(attempt: Int)
	case retreivingDatabase(nodeCount: Int)
	case communicating
	case subscribed

	var description: String {
		switch self {
		case .uninitialized:
			return "Uninitialized"
		case .idle:
			return "Idle"
		case .discovering:
			return "Discovering"
		case .connecting:
			return "Connecting"
		case .retrying(let attempt):
			return "Retrying Connection (\(attempt))"
		case .communicating:
			return "Communicating"
		case .subscribed:
			return "Subscribed"
		case .retreivingDatabase(let nodeCount):
			return "Retreiving Database \(nodeCount)"
		}
	}
}

@MainActor
class AccessoryManager: ObservableObject, MqttClientProxyManagerDelegate {
	// Singleton Access.  Conditionally compiled
#if targetEnvironment(macCatalyst)
	static let shared = AccessoryManager(transports: [BLETransport(), TCPTransport(), SerialTransport()])
#else
	static let shared = AccessoryManager(transports: [BLETransport(), TCPTransport()])
#endif
	
	// Constants
	let NONCE_ONLY_CONFIG = 69420
	let NONCE_ONLY_DB = 69421
	let minimumVersion = "2.3.15"

	// Global Objects
	// Chicken/Egg problem.  Set in the App object immediately after
	// AppState and AccessoryManager are created
	var appState: AppState!
	let context = PersistenceController.shared.container.viewContext
	let mqttManager = MqttClientProxyManager.shared

	// Published Stuff
	@Published var mqttProxyConnected: Bool = false
	@Published var devices: [Device] = []
	@Published var state: AccessoryManagerState
	@Published var mqttError: String = ""
	@Published var activeDeviceNum: Int64?
	@Published var allowDisconnect = false
	@Published var lastConnectionError: Error?
	@Published var isConnected: Bool = false
	@Published var isConnecting: Bool = false

	var activeConnection: (device: Device, connection: any Connection)?

	let transports: [any Transport]

	// Config
	public var wantRangeTestPackets = true
	var wantStoreAndForwardPackets = false
	var shouldAutomaticallyConnectToPreferredPeripheral = true
	
	// Conncetion process
	var connectionSteps: SequentialSteps?
	
	// Public due to file separation
	var rssiUpdateDuringDiscoveryTask: Task <Void, Error>?
	var discoveryTask: Task<Void, Never>?
	var packetTask: Task <Void, Error>?
	var logTask: Task <Void, Error>?
	var rssiTask: Task <Void, Error>?
	var locationTask: Task<Void, Error>?
	var connectionStepper: SequentialSteps?
	
	// Continuations
	private var wantConfigContinuations: [UInt32: CheckedContinuation<Void, Error>] = [:]

	init(transports: [any Transport] = [BLETransport(), TCPTransport()]) {
		self.transports = transports
		self.state = .uninitialized
		self.mqttManager.delegate = self
	}

	func connectToPreferredDevice() {
		if !self.isConnected && !self.isConnecting,
		   let preferredDevice = self.devices.first(where: { $0.id.uuidString == UserDefaults.preferredPeripheralId }) {
			Task { try await self.connect(to: preferredDevice) }
		}
	}

	func sendWantConfig() async {
		guard let connection = activeConnection?.connection else {
			Logger.transport.error("Unable to send wantConfig (config): No device connected")
			return
		}
		try? await sendNonceRequest(nonce: UInt32(NONCE_ONLY_CONFIG), connection: connection)
		Logger.transport.info("✅ [Accessory] NONCE_ONLY_CONFIG Done")
	}

	func sendWantDatabase() async {
		guard let connection = activeConnection?.connection else {
			Logger.transport.error("Unable to send wantConfig (database) : No device connected")
			return
		}

		try? await sendNonceRequest(nonce: UInt32(NONCE_ONLY_DB), connection: connection)
		Logger.transport.info("✅ [Accessory] NONCE_ONLY_DB Done")
	}

	private func sendNonceRequest(nonce: UInt32, connection: any Connection) async throws {
		try await withTaskCancellationHandler {
			// Create the protobuf with the wantConfigID nonce
			var toRadio: ToRadio = ToRadio()
			toRadio.wantConfigID = nonce
			
			// Send it to the radio
			try await self.send(toRadio)
			
			// Start draining packets in the background
			try await connection.startDrainPendingPackets()
			
			// Wait for the nonce request to be completed before continuing
			try await withCheckedThrowingContinuation { cont in
				wantConfigContinuations[nonce] = cont
			}
		} onCancel: {
			Task { @MainActor in
				wantConfigContinuations[nonce]?.resume(throwing: CancellationError())
				wantConfigContinuations[nonce] = nil
			}
		}
	}

	func closeConnection() async throws {
		Logger.transport.debug("[AccessoryManager] received disconnect request")

		// Clean up continuations
		for continuation in self.wantConfigContinuations.values {
			continuation.resume(throwing: AccessoryError.disconnected)
		}
		self.wantConfigContinuations.removeAll()
		
		// Close out the connection
		if let activeConnection = activeConnection {
			self.activeConnection = nil
			try await activeConnection.connection.disconnect()
			updateDevice(deviceId: activeConnection.device.id, key: \.connectionState, value: .disconnected)
		}
	}
	
	func disconnect() async throws {
		// Cancel ongoing connection task if it exists
		await self.connectionStepper?.cancel()

		try await closeConnection()

		// Turn off the disconnect buttons
		allowDisconnect = false
		
		// Set state back to discovering
		updateState(.discovering)
	}

	// Update device attributes on MainActor for presentation in the UI
	func updateDevice<T>(deviceId: UUID? = nil, key: WritableKeyPath<Device, T>, value: T) {
		guard let deviceId = deviceId ?? self.activeConnection?.device.id else {
			Logger.transport.error("updateDevice<T> with nil deviceId")
			return
		}

		// Update the active device
		if let activeConnection {
			var device = activeConnection.device
			device[keyPath: key] = value
			self.activeConnection = (device: device, connection: activeConnection.connection)
			self.activeDeviceNum = device.num
		}
		
		// Update the device in the devices array if it exists
		if let index = devices.firstIndex(where: { $0.id == deviceId }) {
			var device = devices[index]
			device[keyPath: key] = value

			// Update the @Published stuff for the UI
			self.objectWillChange.send()
			
			if let index = devices.firstIndex(where: { $0.id == deviceId }) {
				devices[index] = device
			}

		} else {
			Logger.transport.error("Device with ID \(deviceId) not found in devices list.")
		}

	}

	// Update state on MainActor for presentation in the UI
	func updateState(_ newState: AccessoryManagerState) {
		Logger.transport.info("Updating state from \(self.state.description) to \(newState.description)")
		switch newState {
		case .uninitialized, .idle, .discovering:
			self.isConnected = false
			self.isConnecting = false
		case .connecting, .communicating, .retrying, .retreivingDatabase:
			self.isConnected = false
			self.isConnecting = true
		case .subscribed:
			self.isConnected = true
			self.isConnecting = false
		}
		self.state = newState
	}

	func send(_ data: ToRadio, debugDescription: String? = nil) async throws {
		guard let active = activeConnection,
			  await active.connection.isConnected else {
			throw AccessoryError.connectionFailed("Not connected to any device")
		}
		try await active.connection.send(data)
		if let debugDescription {
			Logger.transport.info("📻 \(debugDescription, privacy: .public)")
		}
	}

	func didReceive(result: Result<FromRadio, Error>) {
		switch result {
		case .success(let fromRadio):
			// Logger.transport.info("✅ [Accessory] didReceive: \(fromRadio.payloadVariant.debugDescription)")
			self.processFromRadio(fromRadio)

		case .failure(let error):
			// Handle error, perhaps log and disconnect
			Logger.transport.info("🚨 [Accessory] didReceive with failure: \(error.localizedDescription)")
			lastConnectionError = error
			switch self.state {
			case .connecting, .retrying:
				break
			default:
				Task { try? await self.disconnect() }
			}
		}
	}

	func didReceiveLog(message: String) {
		var log = message
		/// Debug Log Level
		if log.starts(with: "DEBUG |") {
			do {
				let logString = log
				if let coordsMatch = try CommonRegex.COORDS_REGEX.firstMatch(in: logString) {
					log = "\(log.replacingOccurrences(of: "DEBUG |", with: "").trimmingCharacters(in: .whitespaces))"
					log = log.replacingOccurrences(of: "[,]", with: "", options: .regularExpression)
					Logger.radio.debug("🛰️ \(log.prefix(upTo: coordsMatch.range.lowerBound), privacy: .public) \(coordsMatch.0.replacingOccurrences(of: "[,]", with: "", options: .regularExpression), privacy: .private(mask: .none)) \(log.suffix(from: coordsMatch.range.upperBound), privacy: .public)")
				} else {
					log = log.replacingOccurrences(of: "[,]", with: "", options: .regularExpression)
					Logger.radio.debug("🕵🏻‍♂️ \(log.replacingOccurrences(of: "DEBUG |", with: "").trimmingCharacters(in: .whitespaces), privacy: .public)")
				}
			} catch {
				log = log.replacingOccurrences(of: "[,]", with: "", options: .regularExpression)
				Logger.radio.debug("🕵🏻‍♂️ \(log.replacingOccurrences(of: "DEBUG |", with: "").trimmingCharacters(in: .whitespaces), privacy: .public)")
			}
		} else if log.starts(with: "INFO  |") {
			do {
				let logString = log
				if let coordsMatch = try CommonRegex.COORDS_REGEX.firstMatch(in: logString) {
					log = "\(log.replacingOccurrences(of: "INFO  |", with: "").trimmingCharacters(in: .whitespaces))"
					log = log.replacingOccurrences(of: "[,]", with: "", options: .regularExpression)
					Logger.radio.info("🛰️ \(log.prefix(upTo: coordsMatch.range.lowerBound), privacy: .public) \(coordsMatch.0.replacingOccurrences(of: "[,]", with: "", options: .regularExpression), privacy: .private) \(log.suffix(from: coordsMatch.range.upperBound), privacy: .public)")
				} else {
					log = log.replacingOccurrences(of: "[,]", with: "", options: .regularExpression)
					Logger.radio.info("📢 \(log.replacingOccurrences(of: "INFO  |", with: "").trimmingCharacters(in: .whitespaces), privacy: .public)")
				}
			} catch {
				log = log.replacingOccurrences(of: "[,]", with: "", options: .regularExpression)
				Logger.radio.info("📢 \(log.replacingOccurrences(of: "INFO  |", with: "").trimmingCharacters(in: .whitespaces), privacy: .public)")
			}
		} else if log.starts(with: "WARN  |") {
			log = log.replacingOccurrences(of: "[,]", with: "", options: .regularExpression)
			Logger.radio.warning("⚠️ \(log.replacingOccurrences(of: "WARN  |", with: "").trimmingCharacters(in: .whitespaces), privacy: .public)")
		} else if log.starts(with: "ERROR |") {
			log = log.replacingOccurrences(of: "[,]", with: "", options: .regularExpression)
			Logger.radio.error("💥 \(log.replacingOccurrences(of: "ERROR |", with: "").trimmingCharacters(in: .whitespaces), privacy: .public)")
		} else if log.starts(with: "CRIT  |") {
			log = log.replacingOccurrences(of: "[,]", with: "", options: .regularExpression)
			Logger.radio.critical("🧨 \(log.replacingOccurrences(of: "CRIT  |", with: "").trimmingCharacters(in: .whitespaces), privacy: .public)")
		} else {
			log = log.replacingOccurrences(of: "[,]", with: "", options: .regularExpression)
			Logger.radio.debug("📟 \(log, privacy: .public)")
		}
	}

	private func processFromRadio(_ decodedInfo: FromRadio) {
		switch decodedInfo.payloadVariant {
		case .mqttClientProxyMessage(let mqttClientProxyMessage):
			handleMqttClientProxyMessage(mqttClientProxyMessage)

		case .clientNotification(let clientNotification):
			handleClientNotification(clientNotification)

		case .myInfo(let myNodeInfo):
			handleMyInfo(myNodeInfo)

		case .packet(let packet):
			if case let .decoded(data) = packet.payloadVariant {
				switch data.portnum {
				case .textMessageApp, .detectionSensorApp, .alertApp:
					handleTextMessageAppPacket(packet)
				case .remoteHardwareApp:
					Logger.mesh.info("🕸️ MESH PACKET received for Remote Hardware App UNHANDLED \((try? decodedInfo.packet.jsonString()) ?? "JSON Decode Failure", privacy: .public)")
				case .positionApp:
					upsertPositionPacket(packet: packet, context: context)
				case .waypointApp:
					waypointPacket(packet: packet, context: context)
				case .nodeinfoApp:
					upsertNodeInfoPacket(packet: packet, context: context)
				case .routingApp:
					guard let deviceNum = activeConnection?.device.num else {
						Logger.mesh.error("🕸️ No active connection. Unable to determine connectedNodeNum for routingPacket.")
						return
					}
					routingPacket(packet: packet, connectedNodeNum: deviceNum, context: context)
				case .adminApp:
					adminAppPacket(packet: packet, context: context)
				case .replyApp:
					Logger.mesh.info("🕸️ MESH PACKET received for Reply App handling as a text message")
					guard let deviceNum = activeConnection?.device.num else {
						Logger.mesh.error("🕸️ No active connection. Unable to determine connectedNodeNum for replyApp.")
						return
					}
					textMessageAppPacket(packet: packet, wantRangeTestPackets: wantRangeTestPackets, connectedNode: deviceNum, context: context, appState: appState)
				case .ipTunnelApp:
					Logger.mesh.info("🕸️ MESH PACKET received for IP Tunnel App UNHANDLED UNHANDLED")
				case .serialApp:
					Logger.mesh.info("🕸️ MESH PACKET received for Serial App UNHANDLED UNHANDLED")
				case .storeForwardApp:
					guard let deviceNum = activeConnection?.device.num else {
						Logger.mesh.error("🕸️ No active connection. Unable to determine connectedNodeNum for storeAndForward.")
						return
					}
					storeAndForwardPacket(packet: decodedInfo.packet, connectedNodeNum: deviceNum)
				case .rangeTestApp:
					guard let deviceNum = activeConnection?.device.num else {
						Logger.mesh.error("🕸️ No active connection. Unable to determine connectedNodeNum for rangeTestApp.")
						return
					}
					if wantRangeTestPackets {
						textMessageAppPacket(
							packet: packet,
							wantRangeTestPackets: true,
							connectedNode: deviceNum,
							context: context,
							appState: appState
						)
					} else {
						Logger.mesh.info("🕸️ MESH PACKET received for Range Test App Range testing is disabled.")
					}
				case .telemetryApp:
					guard let deviceNum = activeConnection?.device.num else {
						Logger.mesh.error("🕸️ No active connection. Unable to determine connectedNodeNum for telemetryApp.")
						return
					}
					telemetryPacket(packet: packet, connectedNode: deviceNum, context: context)
				case .textMessageCompressedApp:
					Logger.mesh.info("🕸️ MESH PACKET received for Text Message Compressed App UNHANDLED")
				case .zpsApp:
					Logger.mesh.info("🕸️ MESH PACKET received for Zero Positioning System App UNHANDLED")
				case .privateApp:
					Logger.mesh.info("🕸️ MESH PACKET received for Private App UNHANDLED UNHANDLED")
				case .atakForwarder:
					Logger.mesh.info("🕸️ MESH PACKET received for ATAK Forwarder App UNHANDLED UNHANDLED")
				case .simulatorApp:
					Logger.mesh.info("🕸️ MESH PACKET received for Simulator App UNHANDLED UNHANDLED")
				case .audioApp:
					Logger.mesh.info("🕸️ MESH PACKET received for Audio App UNHANDLED UNHANDLED")
				case .tracerouteApp:
					handleTraceRouteApp(packet)
				case .neighborinfoApp:
					if let neighborInfo = try? NeighborInfo(serializedBytes: decodedInfo.packet.decoded.payload) {
						Logger.mesh.info("🕸️ MESH PACKET received for Neighbor Info App UNHANDLED \((try? neighborInfo.jsonString()) ?? "JSON Decode Failure", privacy: .public)")
					}
				case .paxcounterApp:
					paxCounterPacket(packet: decodedInfo.packet, context: context)
				case .mapReportApp:
					Logger.mesh.info("🕸️ MESH PACKET received Map Report App UNHANDLED \((try? decodedInfo.packet.jsonString()) ?? "JSON Decode Failure", privacy: .public)")
				case .UNRECOGNIZED:
					Logger.mesh.info("🕸️ MESH PACKET received UNRECOGNIZED App UNHANDLED \((try? decodedInfo.packet.jsonString()) ?? "JSON Decode Failure", privacy: .public)")
				case .max:
					Logger.services.info("MAX PORT NUM OF 511")
				case .atakPlugin:
					Logger.mesh.info("🕸️ MESH PACKET received for ATAK Plugin App UNHANDLED \((try? decodedInfo.packet.jsonString()) ?? "JSON Decode Failure", privacy: .public)")
				case .powerstressApp:
					Logger.mesh.info("🕸️ MESH PACKET received for Power Stress App UNHANDLED \((try? decodedInfo.packet.jsonString()) ?? "JSON Decode Failure", privacy: .public)")
				case .reticulumTunnelApp:
					Logger.mesh.info("🕸️ MESH PACKET received for Reticulum Tunnel App UNHANDLED \((try? decodedInfo.packet.jsonString()) ?? "JSON Decode Failure", privacy: .public)")
				case .keyVerificationApp:
					Logger.mesh.warning("🕸️ MESH PACKET received for Key Verification App UNHANDLED \((try? decodedInfo.packet.jsonString()) ?? "JSON Decode Failure", privacy: .public)")
				case .unknownApp:
					Logger.mesh.warning("🕸️ MESH PACKET received for unknown App UNHANDLED \((try? decodedInfo.packet.jsonString()) ?? "JSON Decode Failure", privacy: .public)")
				case .cayenneApp:
					Logger.mesh.info("🕸️ MESH PACKET received Cayenne App UNHANDLED \((try? decodedInfo.packet.jsonString()) ?? "JSON Decode Failure", privacy: .public)")
				}
			}

		case .nodeInfo(let nodeInfo):
			handleNodeInfo(nodeInfo)

		case .channel(let channel):
			handleChannel(channel)

		case .config(let config):
			handleConfig(config)

		case .moduleConfig(let moduleConfig):
			handleModuleConfig(moduleConfig)

		case .metadata(let metadata):
			handleDeviceMetadata(metadata)

		case .deviceuiConfig:
			Logger.mesh.warning("🕸️ MESH PACKET received for deviceUIConfig UNHANDLED \((try? decodedInfo.packet.jsonString()) ?? "JSON Decode Failure", privacy: .public)")

		case .fileInfo:
			Logger.mesh.warning("🕸️ MESH PACKET received for fileInfo UNHANDLED \((try? decodedInfo.packet.jsonString()) ?? "JSON Decode Failure", privacy: .public)")

		case .queueStatus:
			Logger.mesh.warning("🕸️ MESH PACKET received for queueStatus UNHANDLED \((try? decodedInfo.packet.jsonString()) ?? "JSON Decode Failure", privacy: .public)")

		case .configCompleteID(let configCompleteID):
			// Not sure if we want to do anythign here directly?  The continuation stuff lets you
			// do the next step right in the connection flow.

			// switch configCompleteID {
			// case UInt32(NONCE_ONLY_CONFIG):
			//	break;
			// case UInt32(NONCE_ONLY_DB):
			// 	break;
			// break:
			// Logger.mesh.error("✅ [Accessory] Unknown UNHANDLED confligCompleteID: \(configCompleteID)")
			// }

			Logger.transport.info("✅ [Accessory] Notifying completions that have completed for confligCompleteID: \(configCompleteID)")
			if let continuation = wantConfigContinuations[configCompleteID] {
				wantConfigContinuations.removeValue(forKey: configCompleteID)
				continuation.resume()
			}
			
		case .rebooted:
			// If we had an existing connection, then we can probably get away with just a wantConfig?
			if state == .subscribed {
				Task { await sendWantConfig() }
			}
			
		default:
			Logger.mesh.error("Unknown FromRadio variant: \(decodedInfo.payloadVariant.debugDescription)")
		}

	}
}

extension AccessoryManager {
	func didUpdateRSSI(_ rssi: Int, for deviceId: UUID) {
		updateDevice(deviceId: deviceId, key: \.rssi, value: rssi)
	}
}


extension AccessoryManager {
	var connectedVersion: String? {
		return activeConnection?.device.firmwareVersion
	}

	func checkIsVersionSupported(forVersion: String) -> Bool {
		let myVersion = connectedVersion ?? "0.0.0"
		let supportedVersion = UserDefaults.firmwareVersion == "0.0.0" ||
		forVersion.compare(myVersion, options: .numeric) == .orderedAscending ||
		forVersion.compare(myVersion, options: .numeric) == .orderedSame
		return supportedVersion
	}
}

extension AccessoryManager {
	func setupPeriodicHeartbeat() async {
		Task {
			while Task.isCancelled == false {
				try? await Task.sleep(for: .seconds(5 * 60))
				Logger.transport.debug("[Heartbeat] Sending periodic heartbeat")
				try? await sendHeartbeat()
			}
		}
	}
}
