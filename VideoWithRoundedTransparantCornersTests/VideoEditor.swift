import AVFoundation
import Foundation
import Photos
import AppKit
import QuartzCore
import OSLog

let logger = Logger()

class VideoEditor {
    func export(
        url: URL,
        outputDir: URL,
        size: CGSize
    ) async -> String? {
        do {
            let (asset, video) = try await resizeVideo(videoAsset: AVURLAsset(url: url), targetSize: size, isKeepAspectRatio: false, isCutBlackEdge: false)
            
            try await exportVideo(outputPath: outputDir, asset: asset, videoComposition: video)

            return nil
        } catch let error as YGCVideoError {
            switch error {
            case .videoFileNotFind:
                return NSLocalizedString("video_error_video_file_not_found", comment: "")
            case .videoTrackNotFind:
                return NSLocalizedString("video_error_no_video_track", comment: "")
            case .audioTrackNotFind:
                return NSLocalizedString("video_error_no_audio_track", comment: "")
            case .compositionTrackInitFailed:
                return NSLocalizedString("video_error_could_not_create_composition_track", comment: "")
            case .targetSizeNotCorrect:
                return NSLocalizedString("video_error_wrong_size", comment: "")
            case .timeSetNotCorrect:
                return NSLocalizedString("video_error_wrong_time", comment: "")
            case .noDir:
                return NSLocalizedString("video_error_no_dir", comment: "")
            case .noExportSession:
                return NSLocalizedString("video_error_no_export_session", comment: "")
                case .exporterError(let exporterError):
                return String.localizedStringWithFormat(NSLocalizedString("video_error_exporter_error", comment: ""), exporterError)
            }
        } catch {
            assertionFailure()

            return error.localizedDescription
        }
    }

    private enum YGCVideoError: Error {
        case videoFileNotFind
        case videoTrackNotFind
        case audioTrackNotFind
        case compositionTrackInitFailed
        case targetSizeNotCorrect
        case timeSetNotCorrect
        case noDir
        case noExportSession
        case exporterError(String)
    }

    private enum YGCTimeRange {
        case naturalRange
        case secondsRange(Double, Double)
        case cmtimeRange(CMTime, CMTime)

        func validateTime(videoTime: CMTime) -> Bool {
            switch self {
            case .naturalRange:
                return true
            case let .secondsRange(begin, end):
                let seconds = CMTimeGetSeconds(videoTime)
                if end > begin, begin >= 0, end < seconds {
                    return true
                } else {
                    return false
                }
            case let .cmtimeRange(_, end):
                if CMTimeCompare(end, videoTime) == 1 {
                    return false
                } else {
                    return true
                }
            }
        }
    }

    private enum Way {
        case right, left, up, down
    }

    private func orientationFromTransform(transform: CGAffineTransform) -> (orientation: Way, isPortrait: Bool) {
        var assetOrientation = Way.up
        var isPortrait = false

        if transform.a == 0, transform.b == 1.0, transform.c == -1.0, transform.d == 0 {
            assetOrientation = .right
            isPortrait = true
        } else if transform.a == 0, transform.b == -1.0, transform.c == 1.0, transform.d == 0 {
            assetOrientation = .left
            isPortrait = true
        } else if transform.a == 1.0, transform.b == 0, transform.c == 0, transform.d == 1.0 {
            assetOrientation = .up
        } else if transform.a == -1.0, transform.b == 0, transform.c == 0, transform.d == -1.0 {
            assetOrientation = .down
        }

        return (assetOrientation, isPortrait)
    }

    private func videoCompositionInstructionForTrack(track: AVCompositionTrack, videoTrack: AVAssetTrack, targetSize: CGSize) async throws -> AVMutableVideoCompositionLayerInstruction {
        let instruction = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        let transform = try await videoTrack.load(.preferredTransform)
        let naturalSize = try await videoTrack.load(.naturalSize)
        let assetInfo = orientationFromTransform(transform: transform)
        var scaleToFitRatio = targetSize.width / naturalSize.width

        if assetInfo.isPortrait {
            scaleToFitRatio = targetSize.width / naturalSize.height

            let scaleFactor = CGAffineTransform(scaleX: scaleToFitRatio, y: scaleToFitRatio)

            instruction.setTransform(transform.concatenating(scaleFactor), at: CMTime.zero)
        } else {
            let scaleFactor = CGAffineTransform(scaleX: scaleToFitRatio, y: scaleToFitRatio)

            var concat = transform.concatenating(scaleFactor).concatenating(CGAffineTransform(translationX: 0, y: targetSize.width / 2))

            if assetInfo.orientation == .down {
                let fixUpsideDown = CGAffineTransform(rotationAngle: CGFloat.pi)
                let yFix = naturalSize.height + targetSize.height
                let centerFix = CGAffineTransform(translationX: naturalSize.width, y: yFix)

                concat = fixUpsideDown.concatenating(centerFix).concatenating(scaleFactor)
            }

            instruction.setTransform(concat, at: CMTime.zero)
        }

        return instruction
    }

    private func exportVideo(outputPath: URL, asset: AVAsset, videoComposition: AVMutableVideoComposition?) async throws {
        let fileExists = FileManager.default.fileExists(atPath: outputPath.path())

        logger.debug("Output dir: \(outputPath), exists: \(fileExists)")

        if fileExists {
            do {
                try FileManager.default.removeItem(atPath: outputPath.path())
            } catch {
                logger.error("remove file failed")
            }
        }

        let dir = outputPath.deletingLastPathComponent().path()

        logger.debug("Will try to create dir: \(dir)")

        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        var isDirectory = ObjCBool(false)

        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDirectory), isDirectory.boolValue else {
            logger.error("Could not create dir, or dir is a file")

            throw YGCVideoError.noDir
        }

        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
            logger.error("generate export failed")

            throw YGCVideoError.noExportSession
        }

        exporter.outputURL = outputPath
        exporter.outputFileType = .mov
        exporter.shouldOptimizeForNetworkUse = false

        if let composition = videoComposition {
            exporter.videoComposition = composition
        }

        await exporter.export()

        logger.debug("Status: \(String(describing: exporter.status)), error: \(exporter.error)")

        if exporter.status != .completed {
            throw YGCVideoError.exporterError(exporter.error?.localizedDescription ?? "NO SPECIFIC ERROR")
        }
    }

    private func resizeVideo(videoAsset: AVURLAsset,
                             targetSize: CGSize,
                             isKeepAspectRatio: Bool,
                             isCutBlackEdge: Bool) async throws -> (AVMutableComposition, AVMutableVideoComposition)
    {
        guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first else {
            throw YGCVideoError.videoTrackNotFind
        }


        guard let audioTrack = try await videoAsset.loadTracks(withMediaType: .audio).first else {
            throw YGCVideoError.audioTrackNotFind
        }

        let resizeComposition = AVMutableComposition(urlAssetInitializationOptions: nil)

        guard let compositionVideoTrack = resizeComposition.addMutableTrack(withMediaType: AVMediaType.video, preferredTrackID: videoTrack.trackID) else {
            throw YGCVideoError.compositionTrackInitFailed
        }
        guard let compostiionAudioTrack = resizeComposition.addMutableTrack(withMediaType: AVMediaType.audio, preferredTrackID: audioTrack.trackID) else {
            throw YGCVideoError.compositionTrackInitFailed
        }

        let duration = try await videoAsset.load(.duration)

        try compositionVideoTrack.insertTimeRange(CMTimeRangeMake(start: CMTime.zero, duration: duration), of: videoTrack, at: CMTime.zero)
        try compostiionAudioTrack.insertTimeRange(CMTimeRangeMake(start: CMTime.zero, duration: duration), of: audioTrack, at: CMTime.zero)

        let originTransform = try await videoTrack.load(.preferredTransform)
        let info = orientationFromTransform(transform: originTransform)
        let naturalSize = try await videoTrack.load(.naturalSize)
        let videoNaturaSize: CGSize = if info.isPortrait, info.orientation != .up {
            CGSize(width: naturalSize.height, height: naturalSize.width)
        } else {
            naturalSize
        }

        if videoNaturaSize.width < targetSize.width, videoNaturaSize.height < targetSize.height {
            throw YGCVideoError.targetSizeNotCorrect
        }

        let fitRect: CGRect = if isKeepAspectRatio {
            AVMakeRect(aspectRatio: videoNaturaSize, insideRect: CGRect(origin: CGPoint.zero, size: targetSize))
        } else {
            CGRect(origin: CGPoint.zero, size: targetSize)
        }

        let mainInstruction = AVMutableVideoCompositionInstruction()

        mainInstruction.timeRange = CMTimeRange(start: CMTime.zero, end: duration)

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)

        let finalTransform: CGAffineTransform = if info.isPortrait {
            if isCutBlackEdge {
                originTransform.concatenating(CGAffineTransform(scaleX: fitRect.width / videoNaturaSize.width, y: fitRect.height / videoNaturaSize.height))
            } else {
                originTransform.concatenating(CGAffineTransform(scaleX: fitRect.width / videoNaturaSize.width, y: fitRect.height / videoNaturaSize.height)).concatenating(CGAffineTransform(translationX: fitRect.minX, y: fitRect.minY))
            }

        } else {
            if isCutBlackEdge {
                originTransform.concatenating(CGAffineTransform(scaleX: fitRect.width / videoNaturaSize.width, y: fitRect.height / videoNaturaSize.height))
            } else {
                originTransform.concatenating(CGAffineTransform(scaleX: fitRect.width / videoNaturaSize.width, y: fitRect.height / videoNaturaSize.height)).concatenating(CGAffineTransform(translationX: fitRect.minX, y: fitRect.minY))
            }
        }
        layerInstruction.setTransform(finalTransform, at: CMTime.zero)
        mainInstruction.layerInstructions = [layerInstruction]

        let videoComposition = AVMutableVideoComposition()
        
        videoComposition.frameDuration = CMTimeMake(value: 1, timescale: 30)
        
        let videoLayer = CALayer()
        
        videoLayer.frame = CGRect(x: 0, y: 0, width: targetSize.width, height: targetSize.height)
        videoLayer.backgroundColor = .clear
        
        let maskLayer = CALayer()
        
        maskLayer.frame = videoLayer.bounds
        maskLayer.cornerRadius = 100
        maskLayer.masksToBounds = true
        maskLayer.borderWidth = 50
        maskLayer.backgroundColor = .clear

        videoLayer.mask = maskLayer
        
        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: videoLayer)
        
        if isCutBlackEdge, isKeepAspectRatio {
            videoComposition.renderSize = fitRect.size
        } else {
            videoComposition.renderSize = targetSize
        }

        videoComposition.instructions = [mainInstruction]

        return (resizeComposition, videoComposition)
    }
}
