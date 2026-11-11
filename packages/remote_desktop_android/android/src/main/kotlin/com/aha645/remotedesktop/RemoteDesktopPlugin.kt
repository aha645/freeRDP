package com.aha645.remotedesktop

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.view.TextureRegistry

/**
 * 텍스처 plugin (설계 4장).
 *
 * MethodChannel `remote_desktop/texture`:
 *  - createTexture {width, height} → {textureId, sinkPtr}
 *  - resizeTexture {textureId, width, height}
 *  - disposeTexture {textureId}
 *  - (네이티브 → Dart) surfaceAvailable(textureId): Surface가 새로 만들어져 다시 그려야 함
 *
 * 픽셀은 이 클래스를 거치지 않습니다. rdp_bridge가 Surface에 직접 씁니다.
 */
class RemoteDesktopPlugin :
    FlutterPlugin,
    MethodCallHandler {
    private class Entry(
        val producer: TextureRegistry.SurfaceProducer,
        val sink: Long
    )

    private lateinit var channel: MethodChannel
    private lateinit var textures: TextureRegistry
    private val entries = HashMap<Long, Entry>()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        NativeSink.nativeInit(binding.applicationContext.filesDir.absolutePath)
        textures = binding.textureRegistry
        channel = MethodChannel(binding.binaryMessenger, "remote_desktop/texture")
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(
        call: MethodCall,
        result: Result
    ) {
        when (call.method) {
            "createTexture" -> {
                val width = call.argument<Int>("width") ?: 1
                val height = call.argument<Int>("height") ?: 1
                result.success(createTexture(width, height))
            }

            "resizeTexture" -> {
                val entry = textureId(call)?.let { entries[it] }
                if (entry != null) {
                    // 크기를 바꾸면 Surface가 새로 만들어지므로 다시 넘겨줍니다.
                    entry.producer.setSize(
                        call.argument<Int>("width") ?: 1,
                        call.argument<Int>("height") ?: 1
                    )
                    NativeSink.nativeSetSurface(entry.sink, entry.producer.surface)
                }
                result.success(null)
            }

            "disposeTexture" -> {
                textureId(call)?.let { entries.remove(it) }?.let(::release)
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    private fun textureId(call: MethodCall): Long? = call.argument<Number>("textureId")?.toLong()

    private fun createTexture(
        width: Int,
        height: Int
    ): Map<String, Any> {
        val producer = textures.createSurfaceProducer()
        producer.setSize(width, height)
        val sink = NativeSink.nativeCreate()
        val id = producer.id()

        producer.setCallback(
            object : TextureRegistry.SurfaceProducer.Callback {
                // 앱이 백그라운드에서 돌아와 Surface가 새로 만들어짐
                override fun onSurfaceAvailable() {
                    NativeSink.nativeSetSurface(sink, producer.surface)
                    channel.invokeMethod("surfaceAvailable", id)
                }

                // Surface가 곧 사라짐: 그리기를 멈춤
                override fun onSurfaceCleanup() {
                    NativeSink.nativeSetSurface(sink, null)
                }
            }
        )
        NativeSink.nativeSetSurface(sink, producer.surface)

        entries[id] = Entry(producer, sink)
        return mapOf("textureId" to id, "sinkPtr" to sink)
    }

    private fun release(entry: Entry) {
        entry.producer.setCallback(null)
        NativeSink.nativeSetSurface(entry.sink, null)
        entry.producer.release()
        NativeSink.nativeDestroy(entry.sink)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        // 엔진이 사라지면 Dart 세션도 끝난 상태이므로 Surface만 떼고 싱크 메모리는 그대로 둡니다.
        // (세션 스레드가 아직 싱크를 참조할 수 있어 해제하면 위험합니다.)
        for (entry in entries.values) {
            entry.producer.setCallback(null)
            NativeSink.nativeSetSurface(entry.sink, null)
            entry.producer.release()
        }
        entries.clear()
    }
}
