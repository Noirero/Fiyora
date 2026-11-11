import 'package:flutter/material.dart';

import '../../services/diagnostic_logger.dart';

/// Beta diagnostics are local-only and intentionally opt-in for manual capture.
class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({super.key});

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  DiagnosticLogger get _logger => DiagnosticLogger.instance;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _logger.record(DiagnosticEvent.diagnosticsOpened);
  }

  void _toggleRecording() {
    if (_logger.manualActive) {
      _logger.stopManual();
    } else if (!_logger.startManual()) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Diagnostics storage is unavailable.')),
      );
    }
    setState(() {});
  }

  Future<void> _export({required bool crash}) async {
    setState(() => _saving = true);
    try {
      await _logger.exportToDownloads(crash: crash);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Saved to Download/FIYORA/Diagnostics. Open in your file manager.'),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Export failed. Verify all-files storage access and free space.'),
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final logging = _logger.manualActive;
    final hasManual = _logger.hasManualLog;
    final hasCrash = _logger.hasCrashReport;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Diagnostic Logger')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Local-only developer diagnostics. Reports can include technical '
            'details about app behavior. Only export reports you intend to share.',
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Manual session', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 8),
                  Text(logging ? 'Recording active' : 'Recording stopped'),
                  const SizedBox(height: 8),
                  const Text(
                    'Starting a new recording REPLACES the previous manual log. '
                    'Crash reports are stored separately.',
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _logger.storageReady ? _toggleRecording : null,
                    icon: Icon(logging ? Icons.stop_circle_outlined : Icons.fiber_manual_record),
                    label: Text(logging ? 'Stop recording' : 'Start new recording'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: hasManual && !_saving ? () => _export(crash: false) : null,
                    icon: const Icon(Icons.save_alt),
                    label: const Text('Export session TXT to Downloads'),
                  ),
                  if (hasManual) ...[
                    const SizedBox(height: 8),
                    Text('Recent session events', style: theme.textTheme.titleSmall),
                    const SizedBox(height: 8),
                    SelectableText(
                      _logger.preview(crash: false, maxCharacters: 2500),
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Automatic crash recovery', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 8),
                  const Text(
                    'A bounded breadcrumb history runs automatically. Android '
                    'exit reasons are best-effort. An uncaught exception does not '
                    'by itself prove the process crashed. Native stack traces '
                    'may be unavailable.',
                  ),
                  if (_logger.startupClassification != null) ...[
                    const SizedBox(height: 8),
                    Text('Previous process: ${_logger.startupClassification}'),
                  ],
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: hasCrash && !_saving ? () => _export(crash: true) : null,
                    icon: const Icon(Icons.save_alt),
                    label: const Text('Export crash / termination TXT'),
                  ),
                  if (hasCrash) ...[
                    const SizedBox(height: 8),
                    Text('Recovered report', style: theme.textTheme.titleSmall),
                    const SizedBox(height: 8),
                    SelectableText(
                      _logger.preview(crash: true, maxCharacters: 3500),
                      style: theme.textTheme.bodySmall,
                    ),
                    TextButton.icon(
                      onPressed: () {
                        _logger.clearCrashReport();
                        setState(() {});
                      },
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('Clear crash report'),
                    ),
                  ] else
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text('No crash report saved.'),
                    ),
                ],
              ),
            ),
          ),
          if (_logger.writeFailed)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                'Warning: at least one diagnostic disk write failed; reports may be incomplete.',
              ),
            ),
        ],
      ),
    );
  }
}
