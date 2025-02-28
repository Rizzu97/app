import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'video_player.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Camera IP Viewer',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final TextEditingController _ipController =
      TextEditingController(text: "192.168.1.1");
  String? _savePath;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _initSavePath();
  }

  Future<void> _initSavePath() async {
    try {
      final Directory directory;
      if (Platform.isIOS) {
        directory = await getApplicationDocumentsDirectory();
      } else if (Platform.isMacOS) {
        // Su macOS, usa la directory Documents dell'utente
        directory = await getApplicationDocumentsDirectory();
      } else {
        // Android e altre piattaforme
        directory = (await getExternalStorageDirectory())!;
      }

      setState(() {
        _savePath = directory.path;
        _isLoading = false;
      });

      print("Path di salvataggio: $_savePath");
    } catch (e) {
      setState(() {
        _isLoading = false;
        _savePath = null; // Imposta esplicitamente a null in caso di errore
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Errore accesso storage: $e')),
        );
      }
      print("Errore accesso storage: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Camera IP Viewer'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _savePath == null
              ? const Center(child: Text('Impossibile accedere allo storage'))
              : Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: TextField(
                        controller: _ipController,
                        decoration: const InputDecoration(
                          labelText: 'Indirizzo I≤ della telecamera',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    ElevatedButton(
                      onPressed: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (context) => Scaffold(
                              appBar: AppBar(
                                title: Text('Stream da ${_ipController.text}'),
                                backgroundColor: Theme.of(context)
                                    .colorScheme
                                    .inversePrimary,
                              ),
                              body: VideoPlayer(
                                deviceIp: _ipController.text,
                                savePath: _savePath!,
                              ),
                            ),
                          ),
                        );
                      },
                      child: const Text('Connetti alla telecamera'),
                    ),
                    const SizedBox(height: 20),
                    const Padding(
                      padding: EdgeInsets.all(16.0),
                      child: Text(
                        'Questa app si connette a una telecamera IP e visualizza il flusso video. '
                        'È possibile catturare fotogrammi e salvarli nella memoria del dispositivo.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                    ElevatedButton(
                      onPressed: () async {
                        try {
                          final result = await const MethodChannel(
                                  'com.example.video_decoder')
                              .invokeMethod('initializeDecoder', {
                            'width': 640,
                            'height': 480,
                            'bufferSize': 4096,
                          });
                          print("Risultato inizializzazione: $result");
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                                content: Text('Inizializzazione: $result')),
                          );
                        } catch (e) {
                          print("Errore inizializzazione: $e");
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Errore: $e')),
                          );
                        }
                      },
                      child: const Text('Test Inizializzazione'),
                    ),
                    ElevatedButton(
                      onPressed: () async {
                        try {
                          final result = await const MethodChannel(
                                  'com.example.video_decoder')
                              .invokeMethod('checkStatus');
                          print("Stato: $result");
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Stato: $result')),
                          );
                        } catch (e) {
                          print("Errore: $e");
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Errore: $e')),
                          );
                        }
                      },
                      child: const Text('Verifica Stato'),
                    ),
                    ElevatedButton(
                      onPressed: () async {
                        try {
                          final result = await const MethodChannel(
                                  'com.example.video_decoder')
                              .invokeMethod('testConnection', {
                            'ip': _ipController.text,
                          });
                          print("Test connessione: $result");
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                                content: Text('Test connessione: $result')),
                          );
                        } catch (e) {
                          print("Errore test connessione: $e");
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                                content: Text('Errore test connessione: $e')),
                          );
                        }
                      },
                      child: const Text('Test Connessione'),
                    ),
                    ElevatedButton(
                      onPressed: () async {
                        try {
                          final result = await const MethodChannel(
                                  'com.example.video_decoder')
                              .invokeMethod('pingHost', {
                            'ip': _ipController.text,
                          });
                          print("Ping: $result");
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Ping: $result')),
                          );
                        } catch (e) {
                          print("Errore ping: $e");
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Errore ping: $e')),
                          );
                        }
                      },
                      child: const Text('Ping Host'),
                    ),
                  ],
                ),
    );
  }

  @override
  void dispose() {
    _ipController.dispose();
    super.dispose();
  }
}
