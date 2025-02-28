import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

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
  late String _deviceIp;

  @override
  void initState() {
    super.initState();
    _deviceIp = widget.deviceIp;
    _initializePlayer();

    // Ascolta i frame in arrivo dal canale nativo
    platform.setMethodCallHandler((call) async {
      if (call.method == 'onFrame' && call.arguments is Uint8List) {
        _frameController.add(call.arguments);
      } else if (call.method == 'onButtonPressed') {
        // Mostra un alert quando il pulsante viene premuto
        if (mounted) {
          _showButtonPressedAlert();
        }
      }
      return null;
    });
  }

  Future<void> _initializePlayer() async {
    try {
      final success = await platform.invokeMethod('initializeDecoder', {
        'width': 1920, // Aumentato per una migliore risoluzione
        'height': 1080, // Aumentato per una migliore risoluzione
        'bufferSize': 8192, // Aumentato per gestire più dati
      });

      print('initializeDecoder success: $success');

      setState(() {
        _isInitialized = success ?? false;
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
            width: double.infinity, // Usa tutta la larghezza disponibile
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

    return StreamBuilder<Uint8List>(
      stream: _frameController.stream,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return Container(
            color: Colors.black,
            child: const Center(
              child: Text(
                'In attesa del video...',
                style: TextStyle(color: Colors.white, fontSize: 24),
              ),
            ),
          );
        }

        // Visualizza l'immagine a schermo intero
        return Image.memory(
          snapshot.data!,
          gaplessPlayback: true, // Importante per evitare flickering
          fit: BoxFit.contain,
          width: double.infinity,
          height: double.infinity,
        );
      },
    );
  }

  Widget _buildControls() {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: ElevatedButton(
        onPressed: _togglePlayback,
        style: ElevatedButton.styleFrom(
          backgroundColor: _isPlaying ? Colors.red : Colors.green,
          foregroundColor: Colors.white,
          minimumSize: const Size(double.infinity, 60), // Pulsante più grande
          textStyle: const TextStyle(fontSize: 20), // Testo più grande
        ),
        child: Text(_isPlaying ? 'STOP' : 'PLAY'),
      ),
    );
  }

  Future<void> _togglePlayback() async {
    if (_isPlaying) {
      await _stopPlayback();
    } else {
      await _startPlayback();
    }
  }

  Future<void> _startPlayback() async {
    try {
      final result = await platform.invokeMethod('startPlayback', {
        'ip': _deviceIp,
        'port': 40005,
        'bufferSize': 8192,
      });

      print('startPlayback result: $result');

      setState(() {
        _isPlaying = result ?? false;
      });

      if (!_isPlaying && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Impossibile avviare la riproduzione')),
        );
      }
    } on PlatformException catch (e) {
      print('Error starting playback: ${e.message}');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Errore: ${e.message}')),
        );
      }
    }
  }

  Future<void> _stopPlayback() async {
    try {
      await platform.invokeMethod('stopPlayback');
      setState(() {
        _isPlaying = false;
      });
    } catch (e) {
      print('Error stopping playback: $e');
    }
  }

  // Aggiungiamo un metodo per mostrare l'alert
  void _showButtonPressedAlert() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Bottone premuto!'),
        backgroundColor: Colors.green,
        duration: Duration(seconds: 2),
      ),
    );
  }

  @override
  void dispose() {
    _stopPlayback();
    _frameController.close();
    platform.invokeMethod('dispose');
    super.dispose();
  }
}
