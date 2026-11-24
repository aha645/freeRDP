import Cocoa
import CoreVideo
import FlutterMacOS

/// 텍스처 plugin (설계 4장). MethodChannel `remote_desktop/texture`:
///  - createTexture {width, height} → {textureId, sinkPtr}
///  - resizeTexture {textureId, width, height}  (macOS는 싱크가 크기를 스스로 맞추므로 할 일 없음)
///  - disposeTexture {textureId}
///
/// 픽셀은 이 클래스를 거치지 않습니다. rdp_bridge가 싱크(RdpAppleSink.c)의 버퍼에 직접 씁니다.
/// 이 클래스의 모든 함수는 메인 스레드에서 실행됩니다.
public class RemoteDesktopPlugin: NSObject, FlutterPlugin {
  private let registry: FlutterTextureRegistry
  private var textures: [Int64: RemoteTexture] = [:]

  init(registry: FlutterTextureRegistry) {
    self.registry = registry
    super.init()
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "remote_desktop/texture", binaryMessenger: registrar.messenger)
    let instance = RemoteDesktopPlugin(registry: registrar.textures)
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let arguments = call.arguments as? [String: Any]
    switch call.method {
    case "createTexture":
      guard let texture = RemoteTexture(registry: registry) else {
        result(FlutterError(code: "sink", message: "프레임 싱크를 만들 수 없습니다", details: nil))
        return
      }
      let id = registry.register(texture)
      texture.textureId = id
      textures[id] = texture
      result(["textureId": id, "sinkPtr": texture.sinkAddress])

    case "resizeTexture":
      result(nil)

    case "disposeTexture":
      if let id = (arguments?["textureId"] as? NSNumber)?.int64Value,
        let texture = textures.removeValue(forKey: id)
      {
        registry.unregisterTexture(id)
        texture.dispose()
      }
      result(nil)

    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

/// 싱크가 새 프레임을 알릴 때 FreeRDP 스레드에서 호출됩니다.
/// 텍스처 객체는 싱크가 살아 있는 동안 보유되어 있으므로(아래 init) 여기서 꺼내도 안전합니다.
private let frameAvailable: @convention(c) (UnsafeMutableRawPointer?) -> Void = { user in
  guard let user = user else { return }
  let texture = Unmanaged<RemoteTexture>.fromOpaque(user).takeUnretainedValue()
  // 엔진 호출은 메인 스레드에서만 합니다. 블록이 texture를 보유하므로 실행될 때까지 살아 있습니다.
  DispatchQueue.main.async { texture.notifyFrame() }
}

/// Flutter 텍스처 하나와 그 프레임 싱크.
///
/// 스레드별 접근
///  - `sink`: 메인 스레드(dispose)와 래스터 스레드(copyPixelBuffer)가 함께 씀 → `lock`으로 보호
///  - `textureId`, `disposed`: 메인 스레드만 씀
final class RemoteTexture: NSObject, FlutterTexture {
  private let registry: FlutterTextureRegistry
  private let lock = NSLock()
  private var sink: UnsafeMutableRawPointer?
  private var disposed = false

  /// Dart에 넘기는 값. 만든 뒤 바뀌지 않습니다.
  private(set) var sinkAddress: Int = 0
  var textureId: Int64 = 0

  init?(registry: FlutterTextureRegistry) {
    self.registry = registry
    super.init()
    // 싱크가 콜백에서 이 객체를 쓰므로, 싱크를 없앨 때(dispose)까지 보유를 하나 더 잡아 둡니다.
    let retained = Unmanaged.passRetained(self)
    guard let created = rdpb_apple_sink_create(frameAvailable, retained.toOpaque()) else {
      retained.release()
      return nil
    }
    sink = created
    sinkAddress = Int(bitPattern: created)
  }

  /// 래스터 스레드에서 호출됩니다. 돌려준 버퍼는 엔진이 쓰고 나서 해제합니다.
  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    lock.lock()
    defer { lock.unlock() }
    // 잠금 안에서 싱크를 쓰므로 dispose가 그 사이에 싱크를 없앨 수 없습니다.
    guard let sink = sink, let buffer = rdpb_apple_sink_copy_pixel_buffer(sink) else {
      return nil
    }
    return Unmanaged<CVPixelBuffer>.fromOpaque(buffer)
  }

  /// 메인 스레드.
  fileprivate func notifyFrame() {
    if !disposed {
      registry.textureFrameAvailable(textureId)
    }
  }

  /// 메인 스레드. Dart가 세션에서 싱크를 뗀 뒤에 호출됩니다(RemoteViewController.dispose).
  func dispose() {
    if disposed { return }
    disposed = true

    lock.lock()
    let old = sink
    sink = nil
    lock.unlock()

    // 여기부터는 래스터 스레드가 싱크에 들어올 수 없고, 그리는 스레드는 이미 떼어져 있습니다.
    if let old = old {
      rdpb_apple_sink_destroy(old)
      Unmanaged.passUnretained(self).release()  // init에서 잡아 둔 보유를 돌려줌
    }
  }
}
