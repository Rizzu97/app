import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class VideoPlayer extends StatefulWidget {
  final String deviceIp;
  final String savePath;

  const VideoPlayer({
    Key? key,
    required this.deviceIp,
    required this.savePath,
  }) : super(key: key);

  @override
  VideoPlayerState createState() => VideoPlayerState();
}

class VideoPlayerState extends State<VideoPlayer> {
  static const platform = MethodChannel('com.example.video_decoder');

  // Controller per lo stream di frame video
  final StreamController<Uint8List> _frameController =
      StreamController<Uint8List>.broadcast();

  // Variabili di stato
  bool _isPlaying = false;
  bool _isInitialized = false;
  String? _errorMessage;

  // Dimensioni del video
  Size? _videoSize;

  // Aggiungi questa variabile
  String _currentProtocol = "Standard";

  // Aggiungi questa variabile
  int _protocolIndex = 0;

  // Aggiungi queste variabili alla classe VideoPlayerState
  Timer? _frameUpdateTimer;
  bool _autoUpdateEnabled = false;

  @override
  void initState() {
    super.initState();
    _initializePlayer();

    // Ascolta i frame in arrivo dal canale nativo
    platform.setMethodCallHandler((call) async {
      if (call.method == 'onFrame' && call.arguments is Uint8List) {
        _frameController.add(call.arguments);
      }
      return null;
    });
  }

  Future<void> _initializePlayer() async {
    try {
      final success = await platform.invokeMethod('initializeDecoder', {
        'width': 1920,
        'height': 1080,
        'bufferSize': 4096,
      });

      print('initializeDecoder success: $success');

      setState(() {
        _isInitialized = success ?? false;
        _videoSize = const Size(1920, 1080);
        if (!_isInitialized) {
          _errorMessage = 'Impossibile inizializzare il decoder video';
        }
      });
    } on PlatformException catch (e) {
      setState(() {
        _errorMessage = 'Errore: ${e.message}';
        _isInitialized = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: Container(
            color: Colors.black,
            child: Center(
              child: _buildVideoView(),
            ),
          ),
        ),
        _buildControls(),
      ],
    );
  }

  Widget _buildVideoView() {
    if (_errorMessage != null) {
      return Text(
        _errorMessage!,
        style: const TextStyle(color: Colors.white),
      );
    }

    if (!_isInitialized) {
      return const CircularProgressIndicator();
    }

    return AspectRatio(
      aspectRatio: _videoSize?.aspectRatio ?? 16 / 9,
      child: StreamBuilder<Uint8List>(
        stream: _frameController.stream,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return Container(
              color: Colors.black,
              child: const Center(
                child: Text(
                  'In attesa del video...',
                  style: TextStyle(color: Colors.white),
                ),
              ),
            );
          }

          print('Received frame with size: ${snapshot.data!.length} bytes');

          // Visualizza l'immagine
          return Image.memory(
            snapshot.data!,
            gaplessPlayback: true, // Importante per evitare flickering
            fit: BoxFit.contain,
          );
        },
      ),
    );
  }

  Widget _buildControls() {
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Column(
        children: [
          // Mostra il protocollo attuale
          Text(
            "Protocollo: $_currentProtocol",
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              ElevatedButton(
                onPressed: _isInitialized ? _togglePlayback : null,
                child: Text(_isPlaying ? 'Stop' : 'Play'),
              ),
              ElevatedButton(
                onPressed: _isInitialized ? _captureFrame : null,
                child: const Text('Cattura Frame'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              ElevatedButton(
                onPressed: _isInitialized ? _switchProtocol : null,
                child: const Text('Cambia Protocollo'),
              ),
              ElevatedButton(
                onPressed: _isInitialized ? _restartPlayer : null,
                child: const Text('Riavvia'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              ElevatedButton(
                onPressed:
                    _isInitialized ? () => _toggleTestFrames(false) : null,
                child: const Text('Disattiva Test'),
              ),
              ElevatedButton(
                onPressed: _isInitialized ? _forceFrameUpdate : null,
                child: const Text('Aggiorna Frame'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ElevatedButton(
            onPressed: _isInitialized ? _toggleAutoUpdate : null,
            child: Text(_autoUpdateEnabled ? 'Auto OFF' : 'Auto ON'),
          ),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: _emergencyReset,
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: const Text('RESET DI EMERGENZA'),
          ),
        ],
      ),
    );
  }

  void _togglePlayback() {
    if (_isPlaying) {
      _stopPlayback();
    } else {
      _startPlayback();
    }
  }

  Future<void> _startPlayback() async {
    try {
      await platform.invokeMethod('startPlayback', {
        'ip': widget.deviceIp,
        'port': 40005,
        'bufferSize': 4096,
      });

      setState(() {
        _isPlaying = true;
        _errorMessage = null;
      });
    } on PlatformException catch (e) {
      setState(() {
        _errorMessage = 'Impossibile avviare la riproduzione: ${e.message}';
      });
    }
  }

  Future<void> _stopPlayback() async {
    try {
      await platform.invokeMethod('stopPlayback');
      setState(() {
        _isPlaying = false;
      });
    } on PlatformException catch (e) {
      debugPrint('Errore nell\'arresto della riproduzione: ${e.message}');
    }
  }

  Future<void> _captureFrame() async {
    try {
      final frame = await platform.invokeMethod('captureFrame');

      if (frame == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content:
                  Text('Impossibile catturare il frame: nessun dato ricevuto')),
        );
        return;
      }

      final timestamp = DateTime.now();
      final fileName = _generateFileName(timestamp);

      await platform.invokeMethod('saveFrame', {
        'data': frame,
        'path': '${widget.savePath}/$fileName',
      });

      if (mounted) {
        // Aggiorna anche la visualizzazione con il frame catturato
        _frameController.add(frame);

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Frame catturato: $fileName')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Impossibile catturare il frame: $e')),
        );
      }
    }
  }

  Future<void> _testFrame() async {
    try {
      final frame = await platform.invokeMethod('captureFrame');
      if (frame != null) {
        _frameController.add(frame);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Frame di test visualizzato')),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Errore: $e')),
      );
    }
  }

  Future<void> _restartPlayer() async {
    await _stopPlayback();
    await _initializePlayer();
  }

  Future<void> _switchProtocol() async {
    try {
      await platform.invokeMethod('switchProtocol');

      // Aggiorna il nome del protocollo
      setState(() {
        _protocolIndex = (_protocolIndex + 1) % 4;
        _currentProtocol =
            ["Standard", "HTTP", "RTSP", "ONVIF"][_protocolIndex];
      });

      if (_isPlaying) {
        await _stopPlayback();
        await _startPlayback();
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content:
                Text('Protocollo telecamera cambiato a $_currentProtocol')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Errore: $e')),
      );
    }
  }

  Future<void> _toggleTestFrames(bool enable) async {
    try {
      await platform.invokeMethod('enableTestFrames', {'enable': enable});
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(enable
                ? 'Frame di test attivati'
                : 'Frame di test disattivati')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Errore: $e')),
      );
    }
  }

  Future<void> _forceFrameUpdate() async {
    try {
      await platform.invokeMethod('forceFrameUpdate');
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Errore nell\'aggiornamento del frame: $e')),
      );
    }
  }

  // Aggiungi questo metodo per attivare/disattivare l'aggiornamento automatico
  void _toggleAutoUpdate() {
    setState(() {
      _autoUpdateEnabled = !_autoUpdateEnabled;

      if (_autoUpdateEnabled) {
        // Avvia il timer per aggiornare il frame ogni 100ms
        _frameUpdateTimer =
            Timer.periodic(const Duration(milliseconds: 100), (timer) {
          if (_isPlaying && _isInitialized) {
            _forceFrameUpdate();
          }
        });
      } else {
        // Ferma il timer
        _frameUpdateTimer?.cancel();
        _frameUpdateTimer = null;
      }
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(_autoUpdateEnabled
            ? 'Aggiornamento automatico attivato'
            : 'Aggiornamento automatico disattivato'),
      ),
    );
  }

  String _generateFileName(DateTime timestamp) {
    return '${timestamp.year}'
        '${timestamp.month.toString().padLeft(2, '0')}'
        '${timestamp.day.toString().padLeft(2, '0')}'
        '${timestamp.hour.toString().padLeft(2, '0')}'
        '${timestamp.minute.toString().padLeft(2, '0')}'
        '${timestamp.second.toString().padLeft(2, '0')}.jpg';
  }

  Future<void> _emergencyReset() async {
    try {
      // Ferma la riproduzione
      await _stopPlayback();

      // Rilascia tutte le risorse
      await platform.invokeMethod('dispose');

      // Attendi un momento
      await Future.delayed(const Duration(seconds: 1));

      // Reinizializza il player
      await _initializePlayer();

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Reset di emergenza completato')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Reset di emergenza fallito: $e')),
      );
    }
  }

  @override
  void dispose() {
    _stopPlayback();
    _frameUpdateTimer?.cancel();
    _frameController.close();
    platform.invokeMethod('dispose');
    super.dispose();
  }
}
