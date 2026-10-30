import AppKit
import AVFoundation

enum CameraRole {case face,belly}
enum CameraSource:String {case depthAIService}
struct CameraInertialObservation:Codable {let stationary:Bool}
struct CameraIntrinsics {let fx:Double,fy:Double,cx:Double,cy:Double;var inertial:CameraInertialObservation?=nil}
struct CameraDepthFrame {let width:Int,height:Int;let millimetersLittleEndian:Data}
struct CameraFrameSet {let source=CameraSource.depthAIService;let sequence:UInt64;let rgbSampleBuffer:CMSampleBuffer;let alignedDepth:CameraDepthFrame?;let intrinsics:CameraIntrinsics?;let capturedAtMilliseconds:Double?;let captureStreamID:String?}
@main enum SnapshotTests {
 static func main()throws {
  var pixel:CVPixelBuffer?
  precondition(CVPixelBufferCreate(nil,64,40,kCVPixelFormatType_32BGRA,nil,&pixel)==kCVReturnSuccess)
  CVPixelBufferLockBaseAddress(pixel!,[])
  memset(CVPixelBufferGetBaseAddress(pixel!),128,CVPixelBufferGetDataSize(pixel!))
  CVPixelBufferUnlockBaseAddress(pixel!,[])
  var format:CMVideoFormatDescription?
  CMVideoFormatDescriptionCreateForImageBuffer(allocator:nil,imageBuffer:pixel!,formatDescriptionOut:&format)
  var sample:CMSampleBuffer?,timing=CMSampleTimingInfo(duration:.invalid,presentationTimeStamp:.zero,decodeTimeStamp:.invalid)
  CMSampleBufferCreateReadyWithImageBuffer(allocator:nil,imageBuffer:pixel!,formatDescription:format!,sampleTiming:&timing,sampleBufferOut:&sample)
  let store=ROBLocalObservationStore.shared
  let raw=Data(repeating:22,count:64*40*2)
  func offer(_ sequence:UInt64,_ time:Double) {
   store.offer(.init(sequence:sequence,rgbSampleBuffer:sample!,alignedDepth:.init(width:64,height:40,millimetersLittleEndian:raw),intrinsics:.init(fx:50,fy:50,cx:32,cy:20),capturedAtMilliseconds:time,captureStreamID:"fixture"),role:.face)
  }
  func get(_ camera:String)->Result<[String:Any],Error> {
   let wait=DispatchSemaphore(value:0);var result:Result<[String:Any],Error>!
   store.snapshot(camera:camera,includeDepth:true,maximumAge:1200){result=$0;wait.signal()}
   precondition(wait.wait(timeout:.now()+3) == .success)
   return result
  }
  let capture=Date().timeIntervalSince1970*1000
  offer(1,capture-3000);offer(2,capture)
  let result=try get("front").get()
  precondition(result["sequence"]as?UInt64==2 && result["captured_at_ms"]as?Double==capture)
  let jpeg=Data(base64Encoded:result["jpeg_base64"]as!String)!
  let image=NSBitmapImageRep(data:jpeg)!
  precondition(image.pixelsWide==64 && image.pixelsHigh==40)
  let depth=result["depth"]as![String:Any]
  precondition(Data(base64Encoded:depth["base64"]as!String)==raw)
  precondition(result["motion_authority"]as?Bool==false && result["robot_registration_verified"]as?Bool==false)
  offer(3,capture-5000)
  if case .success=get("front") {fatalError("Stale pixels accepted")}
  store.offerPanorama(jpeg:jpeg,receivedAt:Date(),sequence:8,generation:2)
  let pano=try get("panorama").get()
  precondition(pano["timestamp_kind"]as?String=="decoder_receipt_not_sensor_exposure" && pano["depth_available"]as?Bool==false)
  print("PASS actual snapshot encoder: latest frame, JPEG geometry, same-frame depth, original timestamps, stale rejection, panorama provenance; no camera/device IO")
 }
}
