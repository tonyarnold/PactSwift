//
//  MockService.swift
//  PactSwift
//
//  Created by Marko Justinek on 15/4/20.
//  Copyright © 2020 Itty Bitty Apps Pty Ltd / PACT Foundation. All rights reserved.
//
//  Permission to use, copy, modify, and/or distribute this software for any
//  purpose with or without fee is hereby granted, provided that the above
//  copyright notice and this permission notice appear in all copies.
//
//  THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
//  WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
//  MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
//  SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
//  WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
//  ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR
//  IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
//

import Foundation
import Nimble

let kTimeout: TimeInterval = 10

///
/// Initializes a `MockService` object that handles Pact interaction testing.
///
/// When initializing with `.secure` scheme, the SSL certificate on Mock Server
/// is a self-signed certificate!
///
open class MockService {

	// MARK: - Properties

	///
	/// The url of `MockService`
	public var baseUrl: String {
		mockServer.baseUrl
	}

	// MARK: - Private properties

	private var pact: Pact
	private var interactions: [Interaction] = []
	private var currentInteraction: Interaction!
	private var allValidated: Bool = true
	private var transferProtocolScheme: MockServer.TransferProtocol

	private let mockServer: MockServer
	private let errorReporter: ErrorReportable

	// MARK: - Initializers

	///
	/// Initializes a `MockService` object that handles Pact interaction testing.
	///
	/// - parameter consumer: Name of the API consumer (eg: "mobile-app")
	/// - parameter provider: Name of the API provider (eg: "atuh-service")
	/// - parameter scheme: HTTP scheme
	///
	/// When initializing with `.secure` scheme, the SSL certificate on Mock Server
	/// is a self-signed certificate!
	///
	public convenience init(consumer: String, provider: String, scheme: MockServer.TransferProtocol = .standard) {
		self.init(consumer: consumer, provider: provider, scheme: scheme, errorReporter: ErrorReporter())
	}

	///
	/// Initializes a `MockService` object that handles Pact interaction testing.
	///
	/// - parameter consumer: Name of the API consumer (eg: "mobile-app")
	/// - parameter provider: Name of the API provider (eg: "atuh-service")
	/// - parameter scheme: HTTP scheme
	/// - parameter errorReporter: Injectable object to intercept errors.
	///
	/// When initializing with `.secure` scheme, the SSL certificate on Mock Server
	/// is a self-signed certificate!
	///
	internal init(consumer: String, provider: String, scheme: MockServer.TransferProtocol = .standard, errorReporter: ErrorReportable? = nil) {
		pact = Pact(consumer: Pacticipant.consumer(consumer), provider: Pacticipant.provider(provider))
		mockServer = MockServer()
		self.errorReporter = errorReporter ?? ErrorReporter()
		self.transferProtocolScheme = scheme
	}

	// MARK: - Interface

	///
	/// Describes the `Interaction` between the consumer and provider.
	///
	/// Returns: `Interaction` object
	///
	/// - parameter description: A description of the API interaction.
	///
	/// NOTE: It is important that the `description` and provider state
	/// combination is unique per consumer-provider contract.
	///
	public func uponReceiving(_ description: String) -> Interaction {
		currentInteraction = Interaction().uponReceiving(description)
		interactions.append(currentInteraction)
		return currentInteraction
	}

	///
	/// Runs the Pact test against the code that makes the API request with 10 second timeout.
	///
	/// - parameter file: The file to report the failing test in
	/// - parameter line: The line on which to report the failing test
	/// - parameter waitFor: Give the test function `waitFor` seconds to test your interaction. Default is 10 seconds
	/// - parameter testFunction: Your code that makes the API request
	/// - parameter testCompleted: Completion block notifying `MockService` the test is done.
	///
	/// Make sure you call the completion block (eg: `testCompleted()`) at the end of your test! If you don't,
	/// your `mockService.run{ }` test will fail with `Waited more than 10.0 seconds` error where time depends on
	/// your `timeout: TimeInterval?`
	///
	public func run(_ file: FileString? = #file, line: UInt? = #line, waitFor timeout: TimeInterval? = nil, testFunction: @escaping (_ testCompleted: @escaping () -> Void) throws -> Void) {
		pact.interactions = [currentInteraction]
		waitForPactUntil(timeout: timeout ?? kTimeout, file: file, line: line) { [unowned self, pactData = pact.data] completion in //swiftlint:disable:this line_length
			self.mockServer.setup(pact: pactData!, protocol: self.transferProtocolScheme) {
				switch $0 {
				case .success:
					do {
						try testFunction {
							completion()
						}
					} catch {
						self.failWith("🚨 Error thrown in test function: \(error.localizedDescription)", file: file, line: line)
					}
				case .failure(let error):
					self.failWith(error.description)
					completion()
				}
			}
		}

		waitForPactUntil(timeout: timeout ?? kTimeout, file: file, line: line) { completion in
			self.mockServer.verify {
				switch $0 {
				case .success:
					completion()
				case .failure(let error):
					self.failWith(error.description, file: file, line: line)
					completion()
				}
			}
		}
	}

	///
	/// Verifies all interactions have passed their Pact test and writes a Pact contract file in JSON format.
	///
	/// - parameter completion: Result of the writing the Pact contract to JSON
	///
	/// By default Pact contracts are written to `/tmp/pacts` folder.
	/// Set `PACT_DIR` to `$(PATH)/to/desired/dir/` in `Build` phase of your `Scheme` to change the location.
	///
	public func finalize(completion: ((Result<String, MockServerError>) -> Void)? = nil) {
		pact.interactions = interactions
		guard let pactData = pact.data, allValidated else {
			completion?(.failure( .validationFaliure))
			return
		}

		self.mockServer.finalize(pact: pactData) {
			switch $0 {
			case .success(let message):
				completion?(.success(message))
			case .failure(let error):
				self.failWith(error.description)
				completion?(.failure(error))
			}
		}
	}

}

// MARK: - Private -

private extension MockService {

	func waitForPactUntil(timeout: TimeInterval, file: FileString?, line: UInt?, action: @escaping (@escaping () -> Void) -> Void) {
		if let file = file, let line = line {
			return waitUntil(timeout: timeout, file: file, line: line, action: action)
		} else {
			return waitUntil(timeout: timeout, action: action)
		}
	}

	func failWith(_ message: String, file: FileString? = nil, line: UInt? = nil) {
		allValidated = false

		if let file = file, let line = line {
			errorReporter.reportFailure(message, file: file, line: line)
		} else {
			errorReporter.reportFailure(message)
		}
	}

}
