//
//  TCPConnection.swift
//  Meshtastic
//
//  Created by Jake Bordens on 7/19/25.
//

import Foundation
import Network
import OSLog
import MeshtasticProtobufs

class TCPConnection: Connection {
	private let connection: NWConnection
	private let queue = DispatchQueue(label: "tcp.connection")
	private var readerTask: Task<Void, Never>?
	private var logMessage: Data = Data()

	weak var packetDelegate: PacketDelegate?

	var isConnected: Bool {
		connection.state == .ready
	}

	init(host: String, port: Int) async throws {
		let nwHost = NWEndpoint.Host(host)
		let nwPort = NWEndpoint.Port(integerLiteral: UInt16(port))
		connection = NWConnection(host: nwHost, port: nwPort, using: .tcp)

		try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
			connection.stateUpdateHandler = { state in
				switch state {
				case .ready:
					cont.resume()
				case .failed(let error):
					cont.resume(throwing: error)
				default:
					break
				}
			}
			connection.start(queue: queue)
		}

		startReader()
	}

	private func waitForMagicBytes() async throws -> Bool {
		let startOfFrame: [UInt8] = [0x94, 0xc3]
		var waitingOnByte = 0
		while true {
			let data = try await receiveData(min: 1, max: 1)
			if data.count != 1 {
				// End of stream
				return false
			}

			if data[0] == startOfFrame[waitingOnByte] {
				waitingOnByte += 1
			} else {
				handleLogByte(data[0])
				waitingOnByte = 0
			}

			if waitingOnByte > 1 {
				return true
			}
		}
	}

	private func handleLogByte(_ byte: UInt8) {
		if byte == UInt8(ascii: "\n") {
			if let logString = String(data: logMessage, encoding: .utf8) {
				packetDelegate?.didReceiveLog(message: logString)
			}
			logMessage.removeAll(keepingCapacity: true)
		} else {
			logMessage.append(byte)
		}
	}

	private func readInteger() async throws -> UInt16? {
		let data = try await receiveData(min: 2, max: 2)
		if data.count == 2 {
			let value = data.withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
			return value
		}
		return nil
	}

	private func startReader() {
		// TODO: @MainActor here because packets come into AccessoryManager out of order otherwise.  Need to figure out the concurrency
		readerTask = Task { @MainActor in
			while isConnected {
				do {
					if try await waitForMagicBytes() == false {
						Logger.data.debug("TCPConnection: EOF while waiting for magic bytes")
						continue
					}
					Logger.data.debug("Found magic byte, waiting for length")

					if let length = try? await readInteger() {
						let payload = try await receiveData(min: Int(length), max: Int(length))
						if let fromRadio = try? FromRadio(serializedBytes: payload) {
							packetDelegate?.didReceive(result: .success(fromRadio))
						} else {
							Logger.services.error("Failed to deserialize FromRadio")
						}
					} else {
						Logger.data.debug("TCPConnection: EOF while waiting for length")
					}
				} catch {
					Logger.services.error("Error reading from TCP: \(error)")
					packetDelegate?.didReceive(result: .failure(error))
					break
				}
			}
			Logger.services.error("End of TCP reading task: isConnected:\(self.isConnected)")
		}
	}

	private func receiveData(min: Int, max: Int) async throws -> Data {
		try await withCheckedThrowingContinuation { cont in
			connection.receive(minimumIncompleteLength: min, maximumLength: max) { content, _, isComplete, error in
				if let error = error {
					cont.resume(throwing: error)
					return
				}
				if isComplete {
					cont.resume(returning: Data())
					return
				}
				cont.resume(returning: content ?? Data())
			}
		}
	}

	func send(_ data: ToRadio) async throws {
		let serialized = try data.serializedData()
		var buffer = Data()
		buffer.append(0x94)
		buffer.append(0xc3)
		var len = UInt16(serialized.count).bigEndian
		withUnsafeBytes(of: &len) { buffer.append(contentsOf: $0) }
		buffer.append(serialized)

		try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
			connection.send(content: buffer, completion: .contentProcessed { error in
				if let error = error {
					cont.resume(throwing: error)
				} else {
					cont.resume()
				}
			})
		}
	}

	func disconnect() async throws {
		readerTask?.cancel()
		connection.cancel()
	}

	func drainPendingPackets() async throws {
		// For TCP, since reader is always running, no need to drain separately
	}

	func startDrainPendingPackets() throws {
		// For TCP, reader is already started
	}
}
