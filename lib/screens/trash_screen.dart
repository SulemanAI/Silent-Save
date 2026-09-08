import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/notification_service.dart';

class TrashScreen extends StatefulWidget {
  const TrashScreen({super.key});

  @override
  State<TrashScreen> createState() => _TrashScreenState();
}

class _TrashScreenState extends State<TrashScreen> with SingleTickerProviderStateMixin {
  bool _isLoading = true;
  List<Map<String, dynamic>> _media = [];
  late TabController _mediaTabController;

  final Set<String> _selectedMediaPaths = {};
  bool get _isSelectionMode => _selectedMediaPaths.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _mediaTabController = TabController(length: 3, vsync: this);
    _loadData();
  }

  @override
  void dispose() {
    _mediaTabController.dispose();
    super.dispose();
  }

  Future<void> _loadData() async {
    setState(() => _isLoading = true);
    final results = await NotificationService.instance.getTrashedMedia();
    if (mounted) {
      setState(() {
        _media = results;
        _isLoading = false;
      });
    }
  }

  List<Map<String, dynamic>> _getFilteredMedia(String type) {
    return _media.where((m) => m['type'] == type).toList();
  }

  void _toggleSelection(String path) {
    setState(() {
      if (_selectedMediaPaths.contains(path)) {
        _selectedMediaPaths.remove(path);
      } else {
        _selectedMediaPaths.add(path);
      }
    });
  }

  Future<void> _restoreSelected() async {
    final paths = _selectedMediaPaths.toList();
    if (paths.isEmpty) return;

    for (final path in paths) {
      await NotificationService.instance.restoreTrashedMedia(path);
    }
    
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${paths.length} item(s) restored.')),
      );
    }
    
    setState(() => _selectedMediaPaths.clear());
    _loadData();
  }

  Future<void> _permanentDeleteSelected() async {
    final paths = _selectedMediaPaths.toList();
    if (paths.isEmpty) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Permanently?'),
        content: Text('Are you sure you want to permanently delete ${paths.length} items? This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      for (final path in paths) {
        await NotificationService.instance.permanentDeleteMedia(path);
      }
      setState(() => _selectedMediaPaths.clear());
      _loadData();
    }
  }

  Future<void> _emptyTrash() async {
    if (_media.isEmpty) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Empty Trash?'),
        content: const Text('Are you sure you want to permanently delete all items in the trash? This cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Empty'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await NotificationService.instance.emptyTrash();
      setState(() => _selectedMediaPaths.clear());
      _loadData();
    }
  }
  
  String _formatTimestamp(dynamic timestampMs) {
    final ts = (timestampMs is int) ? timestampMs : 0;
    if (ts == 0) return 'Unknown';
    final date = DateTime.fromMillisecondsSinceEpoch(ts);
    final now = DateTime.now();
    final diff = now.difference(date);
    if (diff.inDays == 0) return DateFormat('HH:mm').format(date);
    if (diff.inDays == 1) return 'Yesterday ${DateFormat('HH:mm').format(date)}';
    return DateFormat('MMM dd, HH:mm').format(date);
  }

  String _formatTimeRemaining(dynamic timestampMs) {
    final ts = (timestampMs is int) ? timestampMs : 0;
    if (ts == 0) return '';
    final date = DateTime.fromMillisecondsSinceEpoch(ts);
    final expiryDate = date.add(const Duration(hours: 24));
    final diff = expiryDate.difference(DateTime.now());
    
    if (diff.isNegative) return 'Expired';
    if (diff.inHours > 0) return '${diff.inHours}h remaining';
    return '${diff.inMinutes}m remaining';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_isSelectionMode ? '${_selectedMediaPaths.length} Selected' : 'Trash', 
            style: const TextStyle(fontWeight: FontWeight.bold)),
        elevation: 0,
        backgroundColor: Colors.grey.shade900,
        leading: _isSelectionMode 
            ? IconButton(icon: const Icon(Icons.close), onPressed: () => setState(() => _selectedMediaPaths.clear())) 
            : const BackButton(),
        actions: _isSelectionMode
            ? [
                IconButton(
                  icon: const Icon(Icons.restore),
                  onPressed: _restoreSelected,
                ),
                IconButton(
                  icon: const Icon(Icons.delete_forever, color: Colors.redAccent),
                  onPressed: _permanentDeleteSelected,
                ),
              ]
            : [
                if (_media.isNotEmpty)
                  TextButton(
                    onPressed: _emptyTrash,
                    child: const Text('Empty', style: TextStyle(color: Colors.redAccent)),
                  ),
              ],
        bottom: TabBar(
          controller: _mediaTabController,
          indicatorColor: Colors.grey.shade400,
          tabs: [
            Tab(text: 'Photos (${_getFilteredMedia("photo").length})'),
            Tab(text: 'Videos (${_getFilteredMedia("video").length})'),
            Tab(text: 'Audio (${_getFilteredMedia("audio").length})'),
          ],
        ),
      ),
      body: Container(
        color: Colors.black,
        child: _isLoading
            ? const Center(child: CircularProgressIndicator(color: Colors.grey))
            : TabBarView(
                controller: _mediaTabController,
                children: [
                  _buildList('photo', Icons.image),
                  _buildList('video', Icons.videocam),
                  _buildList('audio', Icons.mic),
                ],
              ),
      ),
    );
  }

  Widget _buildList(String type, IconData icon) {
    final items = _getFilteredMedia(type);
    if (items.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 64, color: Colors.grey.shade800),
            const SizedBox(height: 16),
            Text('No $type items in trash', style: TextStyle(color: Colors.grey.shade600)),
          ],
        ),
      );
    }
    
    return ListView.builder(
      padding: const EdgeInsets.all(8),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        final path = item['path'] as String? ?? '';
        final isSelected = _selectedMediaPaths.contains(path);
        
        return Card(
          margin: const EdgeInsets.symmetric(vertical: 4),
          color: isSelected ? Colors.grey.shade800 : Colors.grey.shade900,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: isSelected ? const BorderSide(color: Colors.white, width: 1.5) : BorderSide.none,
          ),
          child: ListTile(
            leading: _isSelectionMode
                ? Icon(isSelected ? Icons.check_circle : Icons.circle_outlined, 
                    color: isSelected ? Colors.white : Colors.grey)
                : Icon(icon, color: Colors.grey, size: 36),
            title: Text(item['name'] as String? ?? 'Unknown', style: const TextStyle(color: Colors.white, fontSize: 14)),
            subtitle: Text(
              '${_formatTimestamp(item['timestampMs'])} • ${_formatTimeRemaining(item['timestampMs'])}',
              style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
            ),
            trailing: _isSelectionMode ? null : PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert, color: Colors.grey),
              onSelected: (value) async {
                if (value == 'restore') {
                  await NotificationService.instance.restoreTrashedMedia(path);
                  _loadData();
                }
                if (value == 'delete') {
                  await NotificationService.instance.permanentDeleteMedia(path);
                  _loadData();
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'restore', child: Row(children: [
                  Icon(Icons.restore, size: 20), SizedBox(width: 12), Text('Restore'),
                ])),
                const PopupMenuItem(value: 'delete', child: Row(children: [
                  Icon(Icons.delete_forever, size: 20, color: Colors.red), SizedBox(width: 12),
                  Text('Delete Permanently', style: TextStyle(color: Colors.red)),
                ])),
              ],
            ),
            onTap: () {
              if (_isSelectionMode) {
                _toggleSelection(path);
              }
            },
            onLongPress: () {
              if (!_isSelectionMode) {
                _toggleSelection(path);
              }
            },
          ),
        );
      },
    );
  }
}
