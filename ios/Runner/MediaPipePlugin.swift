import Flutter
import UIKit
import MediaPipeTasksVision

public class MediaPipePlugin: NSObject, FlutterPlugin {

    private var faceLandmarker: FaceLandmarker?
    private let channel: FlutterMethodChannel

    // Landmark indices
    private let leftEye  = [362, 385, 387, 263, 373, 380]
    private let rightEye = [33,  160, 158, 133, 153, 144]

    init(channel: FlutterMethodChannel) {
        self.channel = channel
        super.init()
        initFaceLandmarker()
    }

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "mediapipe_channel",
            binaryMessenger: registrar.messenger()
        )
        let instance = MediaPipePlugin(channel: channel)
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    private func initFaceLandmarker() {
        guard let modelPath = Bundle.main.path(
            forResource: "face_landmarker",
            ofType: "task"
        ) else { return }

        let options = FaceLandmarkerOptions()
        options.baseOptions.modelAssetPath = modelPath
        options.runningMode = .image
        options.numFaces = 1
        options.minFaceDetectionConfidence = 0.5
        options.minTrackingConfidence = 0.5

        faceLandmarker = try? FaceLandmarker(options: options)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "analyzeFrame":
            guard let args = call.arguments as? [String: Any],
                  let imageBytes = args["imageBytes"] as? FlutterStandardTypedData
            else {
                result(FlutterError(code: "INVALID_INPUT",
                                   message: "No image bytes", details: nil))
                return
            }

            DispatchQueue.global(qos: .userInitiated).async {
                let analysisResult = self.analyzeFrame(imageBytes.data)
                DispatchQueue.main.async { result(analysisResult) }
            }

        case "isInitialized":
            result(faceLandmarker != nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func analyzeFrame(_ data: Data) -> [String: Any] {
        guard let uiImage = UIImage(data: data),
              let cgImage = uiImage.cgImage
        else { return emptyResult() }

        let mpImage = try? MPImage(uiImage: uiImage)
        guard let mpImage = mpImage,
              let detection = try? faceLandmarker?.detect(image: mpImage),
              let landmarks = detection.faceLandmarks.first
        else { return emptyResult() }

        let w = Float(cgImage.width)
        let h = Float(cgImage.height)

        let leftEAR  = computeEAR(landmarks: landmarks, indices: leftEye,  w: w, h: h)
        let rightEAR = computeEAR(landmarks: landmarks, indices: rightEye, w: w, h: h)
        let avgEAR   = (leftEAR + rightEAR) / 2.0
        let mar      = computeMAR(landmarks: landmarks, w: w, h: h)
        let (pitch, yaw, roll) = computeHeadPose(landmarks: landmarks, w: w, h: h)

        let eyeClosed   = avgEAR < 0.25
        let yawning     = mar > 0.60
        let headNodding = abs(pitch) > 15.0

        return [
            "faceDetected":    true,
            "ear":             Double(avgEAR),
            "mar":             Double(mar),
            "pitch":           Double(pitch),
            "yaw":             Double(yaw),
            "roll":            Double(roll),
            "eyeClosed":       eyeClosed,
            "yawning":         yawning,
            "headNodding":     headNodding,
            "drowsyGeometric": eyeClosed || yawning || headNodding
        ]
    }

    private func computeEAR(landmarks: [NormalizedLandmark],
                             indices: [Int], w: Float, h: Float) -> Float {
        func pt(_ i: Int) -> (Float, Float) {
            (landmarks[i].x * w, landmarks[i].y * h)
        }
        func dist(_ a: (Float,Float), _ b: (Float,Float)) -> Float {
            sqrt(pow(a.0-b.0, 2) + pow(a.1-b.1, 2))
        }
        let v1 = dist(pt(indices[1]), pt(indices[5]))
        let v2 = dist(pt(indices[2]), pt(indices[4]))
        let h1 = dist(pt(indices[0]), pt(indices[3]))
        return h1 > 0 ? (v1 + v2) / (2.0 * h1) : 0
    }

    private func computeMAR(landmarks: [NormalizedLandmark],
                             w: Float, h: Float) -> Float {
        func pt(_ i: Int) -> (Float, Float) {
            (landmarks[i].x * w, landmarks[i].y * h)
        }
        func dist(_ a: (Float,Float), _ b: (Float,Float)) -> Float {
            sqrt(pow(a.0-b.0, 2) + pow(a.1-b.1, 2))
        }
        let vertical   = dist(pt(13), pt(14))
        let horizontal = dist(pt(61), pt(291))
        return horizontal > 0 ? vertical / horizontal : 0
    }

    private func computeHeadPose(landmarks: [NormalizedLandmark],
                                  w: Float, h: Float) -> (Float, Float, Float) {
        let noseTip  = (landmarks[1].x * w,   landmarks[1].y * h)
        let chin     = (landmarks[152].x * w, landmarks[152].y * h)
        let leftEyeP = (landmarks[226].x * w, landmarks[226].y * h)
        let rightEyeP = (landmarks[446].x * w, landmarks[446].y * h)

        let centerX = (leftEyeP.0 + rightEyeP.0) / 2
        let centerY = (leftEyeP.1 + rightEyeP.1) / 2

        let pitch = ((centerY - h/2) / h) * 45.0
        let yaw   = ((centerX - w/2) / w) * 45.0
        let dx    = rightEyeP.0 - leftEyeP.0
        let dy    = rightEyeP.1 - leftEyeP.1
        let roll  = Float(atan2(Double(dy), Double(dx)) * 180.0 / .pi)

        return (pitch, yaw, roll)
    }

    private func emptyResult() -> [String: Any] {
        return [
            "faceDetected": false, "ear": 0.0, "mar": 0.0,
            "pitch": 0.0, "yaw": 0.0, "roll": 0.0,
            "eyeClosed": false, "yawning": false,
            "headNodding": false, "drowsyGeometric": false
        ]
    }
}