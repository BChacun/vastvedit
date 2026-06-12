import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../models/project.dart';
import '../providers/projects_provider.dart';
import 'project_screen.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(projectsProvider);

    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        elevation: 0,
        title: const Text(
          'VastEdit',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 20),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: ElevatedButton.icon(
              icon: const Icon(Icons.add, size: 16),
              label: const Text('New Project'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.accent,
                foregroundColor: Colors.white,
              ),
              onPressed: () => _newProject(context, ref),
            ),
          ),
        ],
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e', style: const TextStyle(color: Colors.red))),
        data: (projects) => projects.isEmpty
            ? _emptyState(context, ref)
            : _grid(context, ref, projects),
      ),
    );
  }

  Widget _emptyState(BuildContext context, WidgetRef ref) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.video_library_outlined, size: 72, color: AppColors.muted),
          const SizedBox(height: 16),
          const Text('No projects yet', style: TextStyle(color: AppColors.muted, fontSize: 18)),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            icon: const Icon(Icons.add),
            label: const Text('Create your first project'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.accent,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
            ),
            onPressed: () => _newProject(context, ref),
          ),
        ],
      ),
    );
  }

  Widget _grid(BuildContext context, WidgetRef ref, List<Project> projects) {
    return GridView.builder(
      padding: const EdgeInsets.all(20),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 260,
        childAspectRatio: 1.35,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: projects.length,
      itemBuilder: (_, i) => _ProjectCard(
        project: projects[i],
        onTap: () => _open(context, projects[i]),
        onDelete: () => _delete(context, ref, projects[i]),
      ),
    );
  }

  void _newProject(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _NameDialog(controller: controller, title: 'New Project'),
    );
    if (name == null || name.trim().isEmpty) return;

    final project = Project(
      id: const Uuid().v4(),
      name: name.trim(),
      createdAt: DateTime.now(),
      clips: const [],
    );
    await ref.read(projectsProvider.notifier).add(project);
    if (context.mounted) _open(context, project);
  }

  void _open(BuildContext context, Project project) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ProjectScreen(projectId: project.id)),
    );
  }

  void _delete(BuildContext context, WidgetRef ref, Project project) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Delete project?', style: TextStyle(color: Colors.white)),
        content: Text(
          'This will remove "${project.name}" and all its clip references.\n'
          'Source video files will not be deleted.',
          style: const TextStyle(color: AppColors.subtle),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel', style: TextStyle(color: AppColors.muted))),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red[700]),
            child: const Text('Delete', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (ok == true) ref.read(projectsProvider.notifier).remove(project.id);
  }
}

class _ProjectCard extends StatelessWidget {
  final Project project;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _ProjectCard({required this.project, required this.onTap, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.border),
          ),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.video_collection_outlined, color: AppColors.accent, size: 22),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.delete_outline, color: AppColors.muted, size: 18),
                    onPressed: onDelete,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(maxWidth: 24, maxHeight: 24),
                    tooltip: 'Delete project',
                  ),
                ],
              ),
              const Spacer(),
              Text(
                project.name,
                style: const TextStyle(
                    color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 4),
              Text(
                '${project.clips.length} clip${project.clips.length == 1 ? '' : 's'}',
                style: const TextStyle(color: AppColors.muted, fontSize: 11),
              ),
              Text(
                _date(project.createdAt),
                style: const TextStyle(color: AppColors.border, fontSize: 11),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _date(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}

class _NameDialog extends StatelessWidget {
  final TextEditingController controller;
  final String title;

  const _NameDialog({required this.controller, required this.title});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.surface,
      title: Text(title, style: const TextStyle(color: Colors.white)),
      content: TextField(
        controller: controller,
        style: const TextStyle(color: Colors.white),
        autofocus: true,
        decoration: const InputDecoration(
          hintText: 'Project name',
          hintStyle: TextStyle(color: AppColors.muted),
          enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: AppColors.border)),
          focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: AppColors.accent)),
        ),
        onSubmitted: (v) => Navigator.of(context).pop(v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel', style: TextStyle(color: AppColors.muted)),
        ),
        ElevatedButton(
          onPressed: () => Navigator.of(context).pop(controller.text),
          style: ElevatedButton.styleFrom(backgroundColor: AppColors.accent),
          child: const Text('Create', style: TextStyle(color: Colors.white)),
        ),
      ],
    );
  }
}

abstract class AppColors {
  static const bg = Color(0xFF141414);
  static const surface = Color(0xFF1F1F1F);
  static const surface2 = Color(0xFF2A2A2A);
  static const border = Color(0xFF333333);
  static const muted = Color(0xFF666666);
  static const subtle = Color(0xFF999999);
  static const accent = Color(0xFF4A90D9);
  static const success = Color(0xFF4CAF50);
  static const warning = Color(0xFFFFA726);
  static const danger = Color(0xFFEF5350);
}
