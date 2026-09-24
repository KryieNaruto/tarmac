// lib/screens/node_list_screen.dart
import 'package:flutter/material.dart';
import '../app_controller.dart';
import '../widgets/connection_bar.dart';
import '../widgets/node_tile.dart';

class NodeListScreen extends StatelessWidget {
  const NodeListScreen({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(title: const Text('Tarmac')),
          body: Column(
            children: [
              ConnectionBar(controller: controller),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: controller.refreshSubscriptions,
                  child: ListView.builder(
                    itemCount: controller.nodes.length,
                    itemBuilder: (context, index) => NodeTile(node: controller.nodes[index]),
                  ),
                ),
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton(
            onPressed: controller.retestAll,
            tooltip: '仅重测',
            child: const Icon(Icons.speed),
          ),
        );
      },
    );
  }
}
