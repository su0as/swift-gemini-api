// Copyright 2025 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Foundation

@Observable
public final class GeminiLiveClient: NSObject, URLSessionWebSocketDelegate {
    private let audioDataChunks = AudioDataBuffer()
    private let sampleRate: Int = 24000 // Based on mimeType
    private let numChannels: Int = 1    // mono audio
    private let bitsPerSample: Int = 16 // PCM is typically 16-bit
    
    public let setup = Setup()
	public var onSetupComplete: ((Bool) -> Void)?
	
    private var socket: URLSessionWebSocketTask?
    private var apiKey: String = ""
    private var urlSession: URLSession?
    
    private let audioPlayer = StreamingAudioPlayer()
    
    public var onOutputTranscription: ((String) -> Void)?
    public var onInputTranscription: ((String) -> Void)?
    public var onToolCall: ((_ name:String, _ id:String, _ args: [String: Any]) -> Void)?
    
    public var mute:Bool = false
    public var playAudio: Bool = true
	public var input_audio_transcription = true
	public var output_audio_transcription = true
	public var response_modalities = ["AUDIO"]
	public var candidateCount = 1
	public var maxOutputTokens = 1024 // 256
	public var temperature = 0.7
    public var topP = 1
	public var topK = 0
	public var enable_affective_dialog = false
    
    let systemPrompt: String
    
    let model: String
    var host: String
    var version: String
    var language: Language
    var voice: Voice
    var enableGoogleSearch: Bool
    let verbose: Bool
    let automaticActivityDetection: Bool
    let proactive_audio: Bool
    
    private var disconnected = false

    public init(
        model: String = "gemini-live-2.5-flash-preview",
        systemPrompt: String = "You are a helpful assistant.",
        host: String = "generativelanguage.googleapis.com",
        version: String = "v1alpha", // v1beta
        language: Language = .ENGLISH_US,
        voice: Voice = .KORE,
        enableGoogleSearch: Bool = true,
		onSetupComplete: ((Bool) -> Void)? = nil,
        verbose: Bool = false,
        input_audio_transcription:Bool = true,
        output_audio_transcription:Bool = true,
        automaticActivityDetection: Bool = false,
        proactive_audio: Bool = false // does not work with the model
    ) {
        self.model = model
        self.host = host
        self.version = version
        self.systemPrompt = systemPrompt
        self.language = language
        self.voice = voice
        self.enableGoogleSearch = enableGoogleSearch
        self.verbose = verbose
        self.output_audio_transcription = output_audio_transcription
        self.input_audio_transcription = input_audio_transcription
        self.automaticActivityDetection = automaticActivityDetection
        self.proactive_audio = proactive_audio
		self.onSetupComplete = onSetupComplete
        
        super.init()
        
        self.urlSession = URLSession(configuration: .default, delegate: self, delegateQueue: OperationQueue())
    }
    
    public func setOutputTranscription(onOutputTranscription: ((String) -> Void)?) {
        self.onOutputTranscription = onOutputTranscription
    }
    
	public func setInputTranscription(onInputTranscription: ((String) -> Void)?) {
        self.onInputTranscription = onInputTranscription
    }
    
	public func setToolCall(onToolCall: @escaping ((_ name:String, _ id:String, _ args: [String: Any]) -> Void)) {
        self.onToolCall = onToolCall
    }

	public func connect(apiKey: String?) {
        disconnected = false
        
        // if apiKey is not nil and is a string and longer than 0 length then assign api key
        if apiKey != nil && (apiKey!.isEmpty == false) {
            self.apiKey = apiKey!
        }
        
        // Only connect if we aren't already connected.
        guard socket?.state != .running else {
            print("WebSocket is already connected.")
            return
        }
        
        guard let url = URL(string: "wss://\(self.host)/ws/google.ai.generativelanguage.\(self.version).GenerativeService.BidiGenerateContent?key=\(self.apiKey)") else {
            print("Invalid WebSocket URL")
            return
        }
       
        let socket = urlSession!.webSocketTask(with: url)
        self.socket = socket
        socket.resume()
        
		listen()
    }

    public func disconnect() {
        disconnected = true
        Task {
			await self.setup.no()
			onSetupComplete?(false)
        }
        audioPlayer.stop()
        print("disconnecting...")
        socket?.cancel(with: .goingAway, reason: nil)
    }
    
	public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        print("web socket opened!")
        
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            self.sendSetup()
        }
    }
    
	public func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        disconnected = true
        print("web socket closed! close code \(closeCode)")
        self.socket = nil
		Task {
			await self.setup.no()
			onSetupComplete?(false)
		}
    }
    
	public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            print("❌ WebSocket task failed with error: \(error.localizedDescription)")
        } else {
//            print("✅ WebSocket task completed successfully.")
        }
    }
    
	@Sendable
    private func checkSetupComplete(_ jsonObject: [String: Any]) {
        if let setupComplete = jsonObject["setupComplete"] {
			switch setupComplete {
			case _ as Bool:
				Task {
					await self.setup.yes()
					onSetupComplete?(true)
				}
			case _ as [String: Any]:
				Task {
					await self.setup.yes()
					onSetupComplete?(true)
				}
			default:
				break
            }
        }
    }
    
    private func dumpData(_ data: Data) {
        guard var jsonObject = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            fatalError("Failed to parse JSON")
        }

        // Navigate and update the `data` field
        if var serverContent = jsonObject["serverContent"] as? [String: Any],
           var modelTurn = serverContent["modelTurn"] as? [String: Any],
           var parts = modelTurn["parts"] as? [[String: Any]],
           var inlineData = parts[0]["inlineData"] as? [String: Any] {

            inlineData["data"] = "LONG_AUDIO_DATA"
            parts[0]["inlineData"] = inlineData
            modelTurn["parts"] = parts
            serverContent["modelTurn"] = modelTurn
            jsonObject["serverContent"] = serverContent
        }
        
        print("🧩 Parsed JSON from data: \(jsonObject)")
    }
    
    private func onData(_ data: Data) {
        print("📦 Received binary data (\(data.count) bytes)")
		Task { @Sendable in
			do {
				if let jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
					dumpData(data)

					if !(await setup.didComplete()) {
						self.checkSetupComplete(jsonObject)
					}
					
					// Process toolCall
					if let toolCall = jsonObject["toolCall"] as? [String: Any] {
	//                    ["toolCall": {
	//                        functionCalls =     (
	//                                    {
	//                                args =             {
	//                                    attendees =                 (
	//                                        Nataliya
	//                                    );
	//                                    date = "2025-10-01";
	//                                    time = "12:00";
	//                                    topic = BCI;
	//                                };
	//                                id = "function-call-3279309317706449416";
	//                                name = "schedule_meeting";
	//                            }
	//                        );
	//                    }]
							// parse above structure
							if let functionCalls = toolCall["functionCalls"] as? [[String: Any]] {
							for functionCall in functionCalls {
								let name = functionCall["name"] as? String
								let args = functionCall["args"] as? [String: Any]
								let id = functionCall["id"] as? String
								self.onToolCall?(name ?? "", id ?? "", args ?? [:])
							}
						}
					}
					
					// Process serverContent
					if let serverContent = jsonObject["serverContent"] as? [String: Any] {
						if let outputTranscription = serverContent["outputTranscription"] as? [String: Any],
						   let text = outputTranscription["text"] as? String {
							self.onOutputTranscription?(text)
						}
						
						if let inputTranscription = serverContent["inputTranscription"] as? [String: Any],
						   let text = inputTranscription["text"] as? String {
							self.onInputTranscription?(text)
						}
						
						if let modelTurn = serverContent["modelTurn"] as? [String: Any],
						   let parts = modelTurn["parts"] as? [[String: Any]] {
							for part in parts {
								if let inlineData = part["inlineData"] as? [String: Any],
								   let base64 = inlineData["data"] as? String,
								   let data = Data(base64Encoded: base64) {
									Task {
										await self.audioDataChunks.append(data)
									}
									
									// playback
									if playAudio {
										self.audioPlayer.enqueue(data)
									}
								}
							}
						}

						if serverContent["generationComplete"] != nil {
							Task {
								await self.writeAudioToWAV()
							}
						}
					}
					
				}
			} catch {
				print("❌ Failed to parse JSON from data: \(error)")
			}
		}
    }
    
    private func writeAudioToWAV() async {
		let pcmData = await audioDataChunks.reduce { chunks in
					chunks.reduce(Data(), +)
				}
        let wavData = createWAVFile(from: pcmData)

        let fileManager = FileManager.default
        let urls = fileManager.urls(for: .documentDirectory, in: .userDomainMask)
        let outputURL = urls[0].appendingPathComponent("gemini_live_response_\(timestamp()).wav")

        do {
            try wavData.write(to: outputURL)
            print("✅ WAV file written to: \(outputURL.path)")
        } catch {
            print("❌ Failed to write WAV file: \(error)")
        }

        // Clear buffer after writing
		Task {
			await audioDataChunks.removeAll()
		}
    }

    private func listen() {
        if socket?.state != .running {
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                self.listen()
            }
        }else {
            socket?.receive { [weak self] result in
                switch result {
                case .success(let message):
                    switch message {
                    case .string(let text):
                        print("📩 Received: \(text)")
                    case .data(let data):
                        self?.onData(data)
                    @unknown default:
                        print("⚠️ Unknown message format")
                    }
                case .failure(let error):
                    if self?.disconnected == false {
                        print("❌ Error receiving message: \(error)")
                    }
                }
                
                // Continue listening
                self?.listen()
            }
        }
    }

    private func send(json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json) else {
            print("Failed to encode JSON")
            return
        }
        
        if let jsonString = String(data: data, encoding: .utf8) {
            socket?.send(.string(jsonString)) { error in
                if let error = error {
                    print("❌ Error sending message: \(error)")
                } else {
                    if self.verbose {
                        print("✅ Sent: \(jsonString)")
                    }
                }
            }
        }
    }
    
    var functionDeclarations: [Any] = []
    
    public func addFunctionDeclarations(_ f:[String: Any] = [
        "name": "schedule_meeting",
        "description": "Schedules a meeting with specified attendees at a given time and date.",
        "parameters": [
          "type": "object",
          "properties": [
            "attendees": [
              "type": "array",
              "items": ["type": "string"],
              "description": "List of people attending the meeting."
            ],
            "date": [
              "type": "string",
              "description": "Date of the meeting (e.g., '2024-07-29')"
            ],
            "time": [
              "type": "string",
              "description": "Time of the meeting (e.g., '15:00')"
            ],
            "topic": [
              "type": "string",
              "description": "The subject or topic of the meeting."
            ]
          ],
          "required": ["attendees", "date", "time", "topic"]
        ]
    ]) {
        functionDeclarations.append(f)
    }

	private func sendSetup() {
		let setup: [String: Any] = [
			"model": "models/\(model)",
			"generationConfig": [
				"candidateCount": candidateCount,
				"maxOutputTokens": maxOutputTokens,
				"temperature": temperature,
				"topP": topP,
				"topK": topK,
				"response_modalities": response_modalities,
				"speech_config": [
					"voice_config": [
						"prebuilt_voice_config": ["voice_name": voice.rawValue]
					],
					"language_code": language.rawValue
				],
				"enable_affective_dialog": enable_affective_dialog ? true : nil
			].compactMapValues { $0 },
			
			"systemInstruction": [
				"parts": [["text": systemPrompt]]
			],

			"realtime_input_config": [
				"automaticActivityDetection": [
					"disabled": automaticActivityDetection,
					"start_of_speech_sensitivity": "START_SENSITIVITY_HIGH",
					"end_of_speech_sensitivity": "END_SENSITIVITY_HIGH",
					"prefix_padding_ms": 20,
					"silence_duration_ms": 100,
				]
			],

			"tools": [
				"functionDeclarations": functionDeclarations,
				"google_search": enableGoogleSearch ? [:] : nil
			].compactMapValues { $0 },

			"proactivity": proactive_audio ? ["proactive_audio": true] : nil,
			"output_audio_transcription": output_audio_transcription ? [:] : nil,
			"input_audio_transcription": input_audio_transcription ? [:] : nil
		].compactMapValues { $0 }

		send(json: ["setup": setup])
	}

    public func sendTextPrompt(_ prompt: String, endOfTurn:Bool = true) {
        var clientContent: [String: Any] = [
            "turns": [
                [
                    "role": "user",
                    "parts": [["text": prompt]]
                ]
            ]
        ]
        
        if endOfTurn {
            clientContent["turnComplete"] = endOfTurn
        }
        
        send(json: ["clientContent":clientContent])
    }
    
	public func sendFunctionResponse(_ id: String, response: [String: Any]) {
        let toolResponse: [String: Any] = [
            "functionResponses": [[
                "id": id,
                "response": response
            ]]
        ]
        
        send(json: ["toolResponse":toolResponse])
    }
    
	public func sendAudio(base64:String) {
        if mute { return }
        
        let message: [String: Any] = [
            "realtimeInput": [
                "mediaChunks": [
                    [
                        "data": base64,
                        "mimeType": "audio/pcm;rate=16000"
                    ]
                ]
            ]
        ]
        
		Task {
			if await self.setup.didComplete() {
				self.send(json: message)
			}
		}
    }
    
    public func sendAudio(data: Data, sampleRate: Int = 24000, bitDepth: Int = 16, channels: Int = 1, silenceSeconds: Int = 1) {
        if mute { return }
        
//        let base64 = data.base64EncodedString()
        let bytesPerSample = bitDepth / 8
        let silenceByteCount = sampleRate * bytesPerSample * channels * silenceSeconds
        let silenceData = Data(repeating: 0, count: silenceByteCount)
        let dataWithSilence = data + silenceData
        let base64 = dataWithSilence.base64EncodedString()
        
        let message: [String: Any] = [
            "realtimeInput": [
                "mediaChunks": [
                    [
                        "data": base64,
                        "mimeType": "audio/pcm"
                    ]
                ]
            ]
        ]
        
		Task {
			if await self.setup.didComplete() {
				self.send(json: message)
			}
		}
    }
    
    public func sendImage(_ base64: String, mimeType: String = "image/jpeg") {
        let message: [String: Any] = [
            "realtimeInput": [
                "mediaChunks": [
                    [
                        "mimeType": mimeType,
                        "data": base64
                    ]
                ]
            ]
        ]

		Task {
			if await self.setup.didComplete() {
				self.send(json: message)
			}
		}
    }
}

public actor Setup {
	private var setupComplete: Bool = false
	
	func yes() {
		self.setupComplete = true
	}
	
	func no() {
		self.setupComplete = false
	}
	
	func didComplete() -> Bool {
		return self.setupComplete
	}
}
