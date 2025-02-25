import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'video_player.dart';

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
      final directory = await getExternalStorageDirectory();
      setState(() {
        _savePath = directory?.path;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Errore: $e')),
        );
      }
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
