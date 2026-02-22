import 'package:flutter/material.dart';
import 'package:haven/src/rust/api/simple.dart';
import 'package:haven/src/rust/frb_generated.dart';

Future<void> main() async {
  await RustLib.init();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Haven',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      home: const HavenHome(),
    );
  }
}

class HavenHome extends StatelessWidget {
  const HavenHome({super.key});

  @override
  Widget build(BuildContext context) {
    final rustGreeting = greet(name: "Jabun");
    return Scaffold(
      appBar: AppBar(
        title: const Text('Haven'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text(
              'FFI Bridge Test',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            Text(rustGreeting, style: const TextStyle(fontSize: 16)),
          ],
        ),
      ),
    );
  }
}
