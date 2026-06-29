import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:app_links/app_links.dart';
import 'dart:convert';
import 'dart:async';
import 'package:url_launcher/url_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const GitShieldApp());
}

final ValueNotifier<ThemeMode> themeNotifier = ValueNotifier(ThemeMode.dark);

class GitShieldApp extends StatelessWidget {
  const GitShieldApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeNotifier,
      builder: (context, mode, _) {
        return MaterialApp(
          title: 'GitShield',
          debugShowCheckedModeBanner: false,
          themeMode: mode,
          theme: ThemeData.light().copyWith(
            scaffoldBackgroundColor: const Color(0xFFF0F4F8),
            colorScheme: const ColorScheme.light(
              primary: Color(0xFF006B3C),
              secondary: Color(0xFF006B3C),
            ),
          ),
          darkTheme: ThemeData.dark().copyWith(
            scaffoldBackgroundColor: const Color(0xFF0D1117),
            colorScheme: const ColorScheme.dark(
              primary: Color(0xFF00FF88),
              secondary: Color(0xFF00FF88),
            ),
          ),
          home: const HomeScreen(),
        );
      },
    );
  }
}

class ScanRecord {
  final String repo;
  final String status;
  final int findings;
  final int riskScore;
  final DateTime timestamp;

  ScanRecord({
    required this.repo,
    required this.status,
    required this.findings,
    required this.riskScore,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
        'repo': repo,
        'status': status,
        'findings': findings,
        'riskScore': riskScore,
        'timestamp': timestamp.toIso8601String(),
      };

  factory ScanRecord.fromJson(Map<String, dynamic> json) => ScanRecord(
        repo: json['repo'],
        status: json['status'],
        findings: json['findings'],
        riskScore: json['riskScore'],
        timestamp: DateTime.parse(json['timestamp']),
      );
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  final TextEditingController _urlController = TextEditingController();
  bool _isLoading = false;
  Map<String, dynamic>? _result;
  String? _error;
  int _selectedTab = 0;

  String _currentStageMessage = "";
  String _currentEngine = "";
  List<Map<String, dynamic>> _liveFindings = [];
  Map<String, List<Map<String, dynamic>>> _fileFindings = {};
  String _currentFile = "";
  int _totalFiles = 0;
  int _scannedFiles = 0;
  String _sseBuffer = "";

  List<ScanRecord> _scanHistory = [];

  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  // ── App Links stream subscription ──
  StreamSubscription<Uri>? _linkSubscription;

  bool get isDark => themeNotifier.value == ThemeMode.dark;
  Color get accentColor =>
      isDark ? const Color(0xFF00FF88) : const Color(0xFF006B3C);
  Color get cardBg => isDark ? const Color(0xFF161B22) : Colors.white;
  Color get surfaceBg =>
      isDark ? const Color(0xFF0D1117) : const Color(0xFFF0F4F8);

  final String backendUrl = "http://127.0.0.1:5000";
  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1000));
    _pulseAnimation = Tween<double>(begin: 1.0, end: 1.15).animate(
        CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut));
    _loadHistory();
    _initLinks();
  }

  @override
  void dispose() {
    _linkSubscription?.cancel();
    _pulseController.dispose();
    _urlController.dispose();
    super.dispose();
  }

  // ─────────────────────────────────────
  // LINK HANDLING — Initial + New Links
  // ─────────────────────────────────────
  Future<void> _initLinks() async {
    final appLinks = AppLinks();

    // Handle initial link (app opened from link)
    try {
      final uri = await appLinks.getInitialLink();
      if (uri != null && uri.toString().contains("github.com")) {
        if (mounted) {
          setState(() {
            _urlController.text = uri.toString();
            _selectedTab = 0;
            _result = null;
            _error = null;
          });
          await Future.delayed(const Duration(milliseconds: 300));
          _scanRepository();
        }
      }
    } catch (e) {}

    // Handle new links while app is already open
    _linkSubscription = appLinks.uriLinkStream.listen(
      (uri) async {
        final url = uri.toString();
        if (url.contains("github.com") && mounted) {
          // If currently scanning, wait for it to finish
          if (_isLoading) {
            _pulseController.stop();
            _pulseController.reset();
          }
          setState(() {
            _urlController.text = url;
            _selectedTab = 0;
            _result = null;
            _error = null;
            _liveFindings = [];
            _fileFindings = {};
            _currentFile = "";
            _currentStageMessage = "";
            _currentEngine = "";
            _totalFiles = 0;
            _scannedFiles = 0;
            _sseBuffer = "";
            _isLoading = false;
          });
          await Future.delayed(const Duration(milliseconds: 300));
          _scanRepository();
        }
      },
      onError: (e) {},
    );
  }

  Future<void> _loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList('scan_history') ?? [];
    setState(() {
      _scanHistory = raw
          .map((e) => ScanRecord.fromJson(jsonDecode(e)))
          .toList()
          .reversed
          .toList();
    });
  }

  Future<void> _saveToHistory(Map<String, dynamic> result) async {
    final findings = result['findings'] as List? ?? [];
    final high = findings.where((f) => f['severity'] == 'HIGH').length;
    final medium = findings.where((f) => f['severity'] == 'MEDIUM').length;
    final riskScore = ((high * 30) + (medium * 10)).clamp(0, 100);

    final record = ScanRecord(
      repo: "${result['owner']}/${result['repo']}",
      status: result['status'] ?? 'CLEAN',
      findings: findings.length,
      riskScore: riskScore,
      timestamp: DateTime.now(),
    );

    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getStringList('scan_history') ?? [];
    existing.add(jsonEncode(record.toJson()));
    if (existing.length > 50) existing.removeAt(0);
    await prefs.setStringList('scan_history', existing);

    setState(() {
      _scanHistory.insert(0, record);
    });
  }

  void _showReviewDialog(String url) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor:
            isDark ? const Color(0xFF1A1800) : Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: Colors.amber, width: 2),
        ),
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded,
                color: Colors.amber, size: 32),
            SizedBox(width: 12),
            Expanded(
              child: Text('Review Recommended',
                  style: TextStyle(
                      color: Colors.amber,
                      fontSize: 18,
                      fontWeight: FontWeight.bold)),
            ),
          ],
        ),
        content: const Text(
          'Suspicious files detected requiring manual verification.\n\n'
          'These files have NOT been executed.\n\n'
          'Do you still want to open this repository?',
          style: TextStyle(fontSize: 14, height: 1.5),
        ),
        actions: [
          TextButton.icon(
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.block, color: Colors.redAccent),
            label: const Text('BLOCK',
                style: TextStyle(
                    color: Colors.redAccent,
                    fontWeight: FontWeight.bold)),
          ),
          ElevatedButton.icon(
            onPressed: () async {
              Navigator.pop(context);
              final uri = Uri.tryParse(url);
              if (uri != null) {
                await launchUrl(uri,
                    mode: LaunchMode.externalApplication);
              }
            },
            icon: const Icon(Icons.open_in_new, size: 18),
            label: const Text('OPEN ANYWAY',
                style: TextStyle(fontWeight: FontWeight.bold)),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.amber,
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
            ),
          ),
        ],
      ),
    );
  }

  // ─────────────────────────────────────
  // SCAN — SSE Streaming
  // ─────────────────────────────────────
  Future<void> _scanRepository() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) {
      setState(() => _error = "Please paste a GitHub link first");
      return;
    }

    setState(() {
      _isLoading = true;
      _result = null;
      _error = null;
      _liveFindings = [];
      _fileFindings = {};
      _currentFile = "";
      _currentStageMessage = "Connecting to GitHub API...";
      _currentEngine = "";
      _totalFiles = 0;
      _scannedFiles = 0;
      _sseBuffer = "";
    });

    _pulseController.repeat(reverse: true);

    final streamUrl =
        "$backendUrl/scan-stream?url=${Uri.encodeComponent(url)}";

    try {
      final httpClient = http.Client();
      final request = http.Request('GET', Uri.parse(streamUrl));
      final streamedResponse = await httpClient.send(request);

      await for (final chunk
          in streamedResponse.stream.transform(utf8.decoder)) {
        if (!mounted) break;

        _sseBuffer += chunk;
        final lines = _sseBuffer.split('\n');
        _sseBuffer = lines.removeLast();

        for (final line in lines) {
          if (!line.startsWith('data: ')) continue;
          final jsonStr = line.substring(6);
          if (jsonStr.isEmpty) continue;

          try {
            final event =
                jsonDecode(jsonStr) as Map<String, dynamic>;
            _handleStreamEvent(event, url);
          } catch (e) {}
        }
      }

      httpClient.close();
    } catch (e) {
      _pulseController.stop();
      _pulseController.reset();
      if (mounted) {
        setState(() {
          _error = "Could not connect to backend.";
          _isLoading = false;
          _currentStageMessage = "";
        });
      }
    }
  }

  void _handleStreamEvent(
      Map<String, dynamic> event, String url) {
    if (!mounted) return;
    final type = event['type'] as String? ?? '';

    setState(() {
      switch (type) {
        case 'stage':
          _currentStageMessage = event['message'] ?? '';
          if (event['total_files'] != null) {
            _totalFiles = event['total_files'];
          }
          break;

        case 'file_start':
          _currentFile = event['filename'] ?? '';
          _currentStageMessage = "Scanning: ${event['filename']}";
          break;

        case 'engine_start':
          _currentEngine = event['engine'] ?? '';
          _currentStageMessage = event['message'] ?? '';
          break;

        case 'engine_done':
          _currentEngine = '';
          _currentStageMessage = event['message'] ?? '';
          final newFindings = (event['findings'] as List? ?? [])
              .map((f) => f as Map<String, dynamic>)
              .toList();
          _liveFindings.addAll(newFindings);
          break;

        case 'file_done':
          _scannedFiles++;
          final fname = event['filename'] as String? ?? '';
          final fileF = (event['file_findings'] as List? ?? [])
              .map((f) => f as Map<String, dynamic>)
              .toList();
          _fileFindings[fname] = fileF;
          break;

        case 'complete':
  _pulseController.stop();
  _pulseController.reset();
  _isLoading = false;
  _result = Map<String, dynamic>.from(event);
  _currentStageMessage = "";
  _currentEngine = "";
  _saveToHistory(event);

  final status = event['status'] ?? 'CLEAN';
  if (status == 'CLEAN') {
    Future.delayed(const Duration(seconds: 2), () async {
      final uri = Uri.tryParse(url);
      if (uri != null && mounted) {
        await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    });
  } else if (status == 'REVIEW RECOMMENDED' && mounted) {
    // Show result card FIRST, then dialog after delay
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) _showReviewDialog(url);
    });
  }
  // THREAT DETECTED — result card shows automatically, no action needed
  break;

        case 'error':
          _pulseController.stop();
          _pulseController.reset();
          _isLoading = false;
          _error = event['message'] ?? 'Unknown error';
          _currentStageMessage = "";
          break;
      }
    });
  }

  void _exportReport() {
    if (_result == null) return;
    final findings = _result!['findings'] as List? ?? [];
    final buffer = StringBuffer();
    buffer.writeln(
        '═══════════════════════════════════════════');
    buffer.writeln(
        '           GITSHIELD SCAN REPORT           ');
    buffer.writeln(
        '═══════════════════════════════════════════');
    buffer.writeln(
        'Repository : ${_result!["owner"]}/${_result!["repo"]}');
    buffer.writeln(
        'Scan Date  : ${DateTime.now().toString().substring(0, 19)}');
    buffer.writeln('Status     : ${_result!["status"]}');
    buffer.writeln(
        'Files Found: ${_result!["total_files_found"]}');
    buffer.writeln(
        'Files Scanned: ${_result!["total_files_scanned"]}');
    buffer.writeln('Total Findings: ${findings.length}');
    buffer.writeln('');
    buffer.writeln(
        '───────────────────────────────────────────');
    buffer.writeln('DETAILED FINDINGS');
    buffer.writeln(
        '───────────────────────────────────────────');
    for (int i = 0; i < findings.length; i++) {
      final f = findings[i];
      buffer.writeln('');
      buffer.writeln('[${i + 1}] ${f["severity"]} — ${f["type"]}');
      buffer.writeln('    File   : ${f["file"]}');
      buffer.writeln('    Engine : ${f["engine"] ?? "N/A"}');
      buffer.writeln('    Detail : ${f["description"]}');
    }
    buffer.writeln('');
    buffer.writeln(
        '═══════════════════════════════════════════');
    buffer.writeln(
        '           END OF REPORT                   ');
    buffer.writeln(
        '═══════════════════════════════════════════');

    Clipboard.setData(ClipboardData(text: buffer.toString()));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Report copied to clipboard'),
        backgroundColor: accentColor,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: surfaceBg,
      appBar: AppBar(
        backgroundColor: cardBg,
        elevation: 0,
        title: Row(
          children: [
            Icon(Icons.shield, color: accentColor, size: 24),
            const SizedBox(width: 8),
            Text('GitShield',
                style: TextStyle(
                    color: accentColor,
                    fontWeight: FontWeight.bold,
                    fontSize: 20)),
          ],
        ),
        actions: [
          IconButton(
            icon: Icon(
              isDark ? Icons.light_mode : Icons.dark_mode,
              color: accentColor,
            ),
            tooltip: isDark ? 'Light mode' : 'Dark mode',
            onPressed: () {
              themeNotifier.value =
                  isDark ? ThemeMode.light : ThemeMode.dark;
            },
          ),
          IconButton(
            icon: Icon(
              _selectedTab == 1
                  ? Icons.history_toggle_off
                  : Icons.history,
              color:
                  _selectedTab == 1 ? Colors.amber : accentColor,
            ),
            tooltip: 'Scan History',
            onPressed: () => setState(() {
              _selectedTab = _selectedTab == 1 ? 0 : 1;
            }),
          ),
          if (_result != null)
            IconButton(
              icon: Icon(Icons.share, color: accentColor),
              tooltip: 'Export Report',
              onPressed: _exportReport,
            ),
        ],
      ),
      body: _selectedTab == 1
          ? _buildHistoryTab()
          : _buildScanTab(),
    );
  }

  Widget _buildScanTab() {
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            const SizedBox(height: 20),

            // ── Animated Shield ──
            AnimatedBuilder(
              animation: _pulseAnimation,
              builder: (context, _) {
                return Transform.scale(
                  scale: _isLoading ? _pulseAnimation.value : 1.0,
                  child: Container(
                    width: 90,
                    height: 90,
                    decoration: BoxDecoration(
                      color: cardBg,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: _isLoading
                            ? Colors.amber
                            : accentColor,
                        width: _isLoading ? 3 : 2,
                      ),
                      boxShadow: _isLoading
                          ? [
                              BoxShadow(
                                  color:
                                      Colors.amber.withOpacity(0.4),
                                  blurRadius: 20,
                                  spreadRadius: 5)
                            ]
                          : [],
                    ),
                    child: Icon(
                      _isLoading ? Icons.radar : Icons.shield,
                      color:
                          _isLoading ? Colors.amber : accentColor,
                      size: 50,
                    ),
                  ),
                );
              },
            ),

            const SizedBox(height: 16),

            Text(
              _isLoading
                  ? 'Scanning...'
                  : 'GitHub Repository Threat Scanner',
              style: TextStyle(
                fontSize: 13,
                color: _isLoading
                    ? Colors.amber
                    : (isDark
                        ? const Color(0xFF8B949E)
                        : Colors.grey[600]),
              ),
            ),

            const SizedBox(height: 32),

            if (!_isLoading) ...[
              Container(
                decoration: BoxDecoration(
                  color: cardBg,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                      color: isDark
                          ? const Color(0xFF30363D)
                          : Colors.grey[300]!),
                ),
                child: TextField(
                  controller: _urlController,
                  style: TextStyle(
                      color: isDark ? Colors.white : Colors.black87,
                      fontSize: 13),
                  decoration: InputDecoration(
                    hintText:
                        'Paste GitHub repository link here...',
                    hintStyle: TextStyle(
                        color: isDark
                            ? const Color(0xFF8B949E)
                            : Colors.grey[500],
                        fontSize: 13),
                    prefixIcon: Icon(Icons.link,
                        color: isDark
                            ? const Color(0xFF8B949E)
                            : Colors.grey[500]),
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 14),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton.icon(
                  onPressed: _scanRepository,
                  icon: const Icon(Icons.security, size: 20),
                  label: const Text('SCAN REPOSITORY',
                      style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1.2)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: accentColor,
                    foregroundColor:
                        isDark ? Colors.black : Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
            ],

            const SizedBox(height: 24),

            if (_isLoading) _buildLiveProgress(),

            if (_error != null)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: isDark
                      ? const Color(0xFF2D1518)
                      : Colors.red[50],
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.redAccent),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.error_outline,
                        color: Colors.redAccent),
                    const SizedBox(width: 10),
                    Expanded(
                        child: Text(_error!,
                            style: const TextStyle(
                                color: Colors.redAccent))),
                  ],
                ),
              ),

            if (_result != null) _buildResultCard(),

            const SizedBox(height: 24),

            if (_result == null &&
                _error == null &&
                !_isLoading)
              _buildInfoCards(),

            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildLiveProgress() {
    final engines = [
      {
        "key": "regex",
        "label": "Regex Engine",
        "icon": Icons.manage_search
      },
      {
        "key": "entropy",
        "label": "Entropy Engine",
        "icon": Icons.analytics
      },
      {
        "key": "sandbox",
        "label": "Sandbox Execution",
        "icon": Icons.verified_user
      },
      {
        "key": "ai",
        "label": "AI Analysis",
        "icon": Icons.smart_toy
      },
    ];

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(16),
        border:
            Border.all(color: Colors.amber.withOpacity(0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                    color: Colors.amber, strokeWidth: 2),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _currentStageMessage,
                  style: const TextStyle(
                      color: Colors.amber,
                      fontWeight: FontWeight.bold,
                      fontSize: 13),
                ),
              ),
            ],
          ),

          if (_totalFiles > 0) ...[
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text("Files: $_scannedFiles / $_totalFiles",
                    style: TextStyle(
                        color: isDark
                            ? Colors.white54
                            : Colors.grey[600],
                        fontSize: 11)),
                Text(
                    "Findings so far: ${_liveFindings.length}",
                    style: const TextStyle(
                        color: Colors.amber, fontSize: 11)),
              ],
            ),
            const SizedBox(height: 6),
            LinearProgressIndicator(
              value: _totalFiles > 0
                  ? _scannedFiles / _totalFiles
                  : 0,
              backgroundColor: isDark
                  ? const Color(0xFF30363D)
                  : Colors.grey[200],
              valueColor: const AlwaysStoppedAnimation<Color>(
                  Colors.amber),
              minHeight: 4,
            ),
          ],

          const SizedBox(height: 16),

          // ── Engine Grid ──
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
            childAspectRatio: 2.6,
            children: engines.map((engine) {
              final isActive =
                  _currentEngine == engine['key'];
              final isDone = _liveFindings.any((f) =>
                  f['engine']
                      ?.toString()
                      .toLowerCase()
                      .contains(engine['key'] as String) ==
                  true);

              return Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: isActive
                      ? Colors.amber.withOpacity(0.15)
                      : isDone
                          ? accentColor.withOpacity(0.1)
                          : (isDark
                              ? const Color(0xFF0D1117)
                              : Colors.grey[100]),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: isActive
                        ? Colors.amber
                        : isDone
                            ? accentColor.withOpacity(0.5)
                            : Colors.transparent,
                  ),
                ),
                child: Row(
                  children: [
                    if (isActive)
                      const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                            color: Colors.amber,
                            strokeWidth: 2),
                      )
                    else if (isDone)
                      Icon(Icons.check_circle,
                          color: accentColor, size: 14)
                    else
                      Icon(engine['icon'] as IconData,
                          color: isDark
                              ? Colors.white24
                              : Colors.grey[400],
                          size: 14),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        engine['label'] as String,
                        style: TextStyle(
                          fontSize: 9,
                          color: isActive
                              ? Colors.amber
                              : isDone
                                  ? accentColor
                                  : (isDark
                                      ? Colors.white38
                                      : Colors.grey[500]),
                          fontWeight: isActive
                              ? FontWeight.bold
                              : FontWeight.normal,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),

          // ── Live Findings Preview ──
          if (_liveFindings.isNotEmpty) ...[
            const SizedBox(height: 14),
            Text(
              "Live Findings (${_liveFindings.length})",
              style: TextStyle(
                  color: isDark
                      ? Colors.white54
                      : Colors.grey[600],
                  fontSize: 11,
                  letterSpacing: 1),
            ),
            const SizedBox(height: 8),
            Container(
              height: 120,
              decoration: BoxDecoration(
                color: isDark
                    ? const Color(0xFF0D1117)
                    : Colors.grey[100],
                borderRadius: BorderRadius.circular(8),
              ),
              child: ListView.builder(
                padding: const EdgeInsets.all(8),
                itemCount: _liveFindings.length,
                itemBuilder: (context, index) {
                  final f = _liveFindings[
                      _liveFindings.length - 1 - index];
                  final color = f['severity'] == 'HIGH'
                      ? Colors.redAccent
                      : f['severity'] == 'MEDIUM'
                          ? Colors.amber
                          : Colors.grey;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(
                      children: [
                        Icon(Icons.circle,
                            color: color, size: 8),
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 1),
                          decoration: BoxDecoration(
                            color: color.withOpacity(0.15),
                            borderRadius:
                                BorderRadius.circular(3),
                          ),
                          child: Text(f['severity'] ?? '',
                              style: TextStyle(
                                  color: color,
                                  fontSize: 9,
                                  fontWeight:
                                      FontWeight.bold)),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            "${f['file']} — ${f['type']}",
                            style: TextStyle(
                                color: isDark
                                    ? Colors.white60
                                    : Colors.black54,
                                fontSize: 10),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildResultCard() {
    final String status = _result!["status"] ?? "CLEAN";
    final bool isThreat = status == "THREAT DETECTED";
    final bool needsReview = status == "REVIEW RECOMMENDED";
    final List findings = _result!["findings"] ?? [];

    Color borderColor;
    Color headerBg;
    IconData statusIcon;

    if (isThreat) {
      borderColor = Colors.redAccent;
      headerBg = const Color(0xFF2D1518);
      statusIcon = Icons.dangerous;
    } else if (needsReview) {
      borderColor = Colors.amber;
      headerBg = const Color(0xFF2D2A15);
      statusIcon = Icons.warning_amber_rounded;
    } else {
      borderColor = const Color(0xFF00FF88);
      headerBg = const Color(0xFF0F2A1B);
      statusIcon = Icons.verified;
    }

    final int highCount =
        findings.where((f) => f["severity"] == "HIGH").length;
    final int mediumCount =
        findings.where((f) => f["severity"] == "MEDIUM").length;
    final int riskScore =
        ((highCount * 30) + (mediumCount * 10)).clamp(0, 100);

    Color riskColor;
    String riskLabel;
    if (riskScore >= 60) {
      riskColor = Colors.redAccent;
      riskLabel = "CRITICAL";
    } else if (riskScore >= 30) {
      riskColor = Colors.orange;
      riskLabel = "HIGH";
    } else if (riskScore >= 10) {
      riskColor = Colors.amber;
      riskLabel = "MEDIUM";
    } else {
      riskColor = accentColor;
      riskLabel = "LOW";
    }

    final Map<String, List> byFile = {};
    for (final f in findings) {
      final fname = f['file'] as String? ?? 'unknown';
      byFile.putIfAbsent(fname, () => []).add(f);
    }

    final engineCounts = <String, int>{};
    for (final f in findings) {
      final engine = (f['engine'] as String? ?? 'Unknown')
          .replaceAll(RegExp(r'Engine \d+ — '), '');
      engineCounts[engine] =
          (engineCounts[engine] ?? 0) + 1;
    }

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: borderColor, width: 2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header ──
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: headerBg,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(14),
                topRight: Radius.circular(14),
              ),
            ),
            child: Row(
              children: [
                Icon(statusIcon,
                    color: borderColor, size: 32),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment:
                        CrossAxisAlignment.start,
                    children: [
                      Text(status,
                          style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              color: borderColor)),
                      Text(
                        isThreat
                            ? "Confirmed threats — do not open"
                            : needsReview
                                ? "Manual verification recommended"
                                : "No threats — safe to access",
                        style: TextStyle(
                            fontSize: 11,
                            color:
                                borderColor.withOpacity(0.7)),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.ios_share,
                      color: borderColor, size: 20),
                  onPressed: _exportReport,
                  tooltip: 'Export Report',
                ),
              ],
            ),
          ),

          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _statRow(Icons.person_outline,
                    "${_result!["owner"]}/${_result!["repo"]}"),
                const SizedBox(height: 4),
                _statRow(Icons.folder_outlined,
                    "Files found: ${_result!["total_files_found"] ?? 0}"),
                const SizedBox(height: 4),
                _statRow(Icons.search,
                    "Files scanned: ${_result!["total_files_scanned"] ?? 0}"),
                const SizedBox(height: 4),
                _statRow(Icons.report_outlined,
                    "Total findings: ${findings.length} (HIGH: $highCount, MEDIUM: $mediumCount)"),

                const SizedBox(height: 16),

                // ── Engine Pattern Counter ──
                if (engineCounts.isNotEmpty) ...[
                  Text("Patterns Checked by Engine",
                      style: TextStyle(
                          color: isDark
                              ? Colors.white54
                              : Colors.grey[600],
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 1)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children:
                        engineCounts.entries.map((entry) {
                      return Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color:
                              borderColor.withOpacity(0.1),
                          borderRadius:
                              BorderRadius.circular(20),
                          border: Border.all(
                              color: borderColor
                                  .withOpacity(0.3)),
                        ),
                        child: Text(
                          "${entry.key}: ${entry.value}",
                          style: TextStyle(
                              color: borderColor,
                              fontSize: 11,
                              fontWeight: FontWeight.bold),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 16),
                ],

                // ── Risk Meter ──
                Row(
                  mainAxisAlignment:
                      MainAxisAlignment.spaceBetween,
                  children: [
                    Text("Confidence Risk Score",
                        style: TextStyle(
                            color: isDark
                                ? Colors.white70
                                : Colors.black87,
                            fontSize: 13,
                            fontWeight: FontWeight.bold)),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color:
                                riskColor.withOpacity(0.15),
                            borderRadius:
                                BorderRadius.circular(6),
                            border: Border.all(
                                color: riskColor
                                    .withOpacity(0.5)),
                          ),
                          child: Text(riskLabel,
                              style: TextStyle(
                                  color: riskColor,
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 1)),
                        ),
                        const SizedBox(width: 8),
                        Text("$riskScore%",
                            style: TextStyle(
                                color: riskColor,
                                fontSize: 18,
                                fontWeight: FontWeight.bold)),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Stack(
                  children: [
                    Container(
                      height: 12,
                      decoration: BoxDecoration(
                        color: isDark
                            ? const Color(0xFF30363D)
                            : Colors.grey[200],
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                    FractionallySizedBox(
                      widthFactor: riskScore / 100,
                      child: Container(
                        height: 12,
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [
                              Color(0xFF00FF88),
                              Colors.amber,
                              Colors.redAccent,
                            ],
                          ),
                          borderRadius:
                              BorderRadius.circular(6),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                const Row(
                  mainAxisAlignment:
                      MainAxisAlignment.spaceBetween,
                  children: [
                    Text("LOW",
                        style: TextStyle(
                            color: Color(0xFF00FF88),
                            fontSize: 9)),
                    Text("MEDIUM",
                        style: TextStyle(
                            color: Colors.amber,
                            fontSize: 9)),
                    Text("CRITICAL",
                        style: TextStyle(
                            color: Colors.redAccent,
                            fontSize: 9)),
                  ],
                ),

                if (findings.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  const Divider(),
                  const SizedBox(height: 8),
                  Text(
                    "FILE-BY-FILE BREAKDOWN (${byFile.length} files)",
                    style: TextStyle(
                        color: isDark
                            ? Colors.white54
                            : Colors.grey[600],
                        fontSize: 11,
                        letterSpacing: 1.5,
                        fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),
                  ...byFile.entries.map((entry) {
                    return _buildFileBreakdown(
                        entry.key, entry.value);
                  }),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFileBreakdown(
      String filename, List fileFindings) {
    final highCount =
        fileFindings.where((f) => f['severity'] == 'HIGH').length;
    final mediumCount = fileFindings
        .where((f) => f['severity'] == 'MEDIUM')
        .length;

    Color fileColor;
    IconData fileIcon;
    if (highCount > 0) {
      fileColor = Colors.redAccent;
      fileIcon = Icons.dangerous_outlined;
    } else if (mediumCount > 0) {
      fileColor = Colors.amber;
      fileIcon = Icons.warning_amber_outlined;
    } else {
      fileColor = accentColor;
      fileIcon = Icons.check_circle_outline;
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Theme(
        data: Theme.of(context)
            .copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          leading:
              Icon(fileIcon, color: fileColor, size: 20),
          title: Text(
            filename.length > 45
                ? '...${filename.substring(filename.length - 45)}'
                : filename,
            style: TextStyle(
                color: fileColor,
                fontSize: 12,
                fontWeight: FontWeight.bold),
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            "${fileFindings.length} finding(s) — HIGH: $highCount  MEDIUM: $mediumCount",
            style: TextStyle(
                color: isDark
                    ? Colors.white38
                    : Colors.grey[500],
                fontSize: 10),
          ),
          collapsedBackgroundColor:
              fileColor.withOpacity(0.05),
          backgroundColor: fileColor.withOpacity(0.08),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side:
                BorderSide(color: fileColor.withOpacity(0.3)),
          ),
          collapsedShape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side:
                BorderSide(color: fileColor.withOpacity(0.2)),
          ),
          iconColor: fileColor,
          collapsedIconColor: fileColor,
          children: fileFindings.map((f) {
            final Color sColor = f['severity'] == 'HIGH'
                ? Colors.redAccent
                : f['severity'] == 'MEDIUM'
                    ? Colors.amber
                    : Colors.grey;

            return Padding(
              padding:
                  const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: isDark
                      ? const Color(0xFF0D1117)
                      : Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                      color: sColor.withOpacity(0.3)),
                ),
                child: Column(
                  crossAxisAlignment:
                      CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: sColor.withOpacity(0.15),
                            borderRadius:
                                BorderRadius.circular(4),
                          ),
                          child: Text(f['severity'] ?? '',
                              style: TextStyle(
                                  color: sColor,
                                  fontSize: 9,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 1)),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.white10,
                            borderRadius:
                                BorderRadius.circular(4),
                          ),
                          child: Text(f['type'] ?? '',
                              style: const TextStyle(
                                  color: Colors.white54,
                                  fontSize: 9)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      f['description'] ?? '',
                      style: TextStyle(
                          color: isDark
                              ? Colors.white70
                              : Colors.black87,
                          fontSize: 11,
                          height: 1.4),
                    ),
                    if (f['engine'] != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        "Detected by: ${f['engine']}",
                        style: TextStyle(
                            color: isDark
                                ? Colors.white30
                                : Colors.grey[400],
                            fontSize: 9),
                      ),
                    ],
                    if (f['context'] != null &&
                        (f['context'] as String)
                            .isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: isDark
                              ? Colors.black45
                              : Colors.grey[100],
                          borderRadius:
                              BorderRadius.circular(6),
                        ),
                        child: Text(
                          f['context'],
                          style: const TextStyle(
                              color: Colors.orange,
                              fontSize: 10,
                              fontFamily: 'monospace'),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildHistoryTab() {
    if (_scanHistory.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.history,
                size: 64,
                color: isDark
                    ? Colors.white12
                    : Colors.grey[300]),
            const SizedBox(height: 16),
            Text("No scan history yet",
                style: TextStyle(
                    color: isDark
                        ? Colors.white38
                        : Colors.grey[500],
                    fontSize: 16)),
            const SizedBox(height: 8),
            Text("Scan a repository to see history here",
                style: TextStyle(
                    color: isDark
                        ? Colors.white24
                        : Colors.grey[400],
                    fontSize: 13)),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _scanHistory.length,
      itemBuilder: (context, index) {
        final record = _scanHistory[index];
        Color statusColor;
        IconData statusIcon;

        if (record.status == "THREAT DETECTED") {
          statusColor = Colors.redAccent;
          statusIcon = Icons.dangerous;
        } else if (record.status == "REVIEW RECOMMENDED") {
          statusColor = Colors.amber;
          statusIcon = Icons.warning_amber_rounded;
        } else {
          statusColor = accentColor;
          statusIcon = Icons.verified;
        }

        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: cardBg,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: statusColor.withOpacity(0.3)),
            ),
            child: Row(
              children: [
                Icon(statusIcon,
                    color: statusColor, size: 28),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment:
                        CrossAxisAlignment.start,
                    children: [
                      Text(record.repo,
                          style: TextStyle(
                              color: isDark
                                  ? Colors.white
                                  : Colors.black87,
                              fontWeight: FontWeight.bold,
                              fontSize: 13),
                          overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 3),
                      Text(
                        "${record.status} — ${record.findings} findings — Risk: ${record.riskScore}%",
                        style: TextStyle(
                            color: statusColor,
                            fontSize: 11),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        _formatDate(record.timestamp),
                        style: TextStyle(
                            color: isDark
                                ? Colors.white38
                                : Colors.grey[500],
                            fontSize: 10),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.refresh,
                      color: accentColor, size: 20),
                  onPressed: () {
                    setState(() {
                      _selectedTab = 0;
                      _urlController.text =
                          "https://github.com/${record.repo}";
                    });
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _formatDate(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return "Just now";
    if (diff.inHours < 1) return "${diff.inMinutes}m ago";
    if (diff.inDays < 1) return "${diff.inHours}h ago";
    return "${dt.day}/${dt.month}/${dt.year}";
  }

  Widget _statRow(IconData icon, String text) {
    return Row(
      children: [
        Icon(icon,
            color: isDark
                ? const Color(0xFF8B949E)
                : Colors.grey[500],
            size: 14),
        const SizedBox(width: 6),
        Expanded(
          child: Text(text,
              style: TextStyle(
                  color: isDark
                      ? Colors.white70
                      : Colors.black54,
                  fontSize: 12)),
        ),
      ],
    );
  }

  Widget _buildInfoCards() {
    final cards = [
      [Icons.bug_report, 'Regex', 'Known signatures'],
      [Icons.analytics, 'Entropy', 'Obfuscation'],
      [Icons.verified_user, 'Sandbox', 'Live execution'],
      [Icons.smart_toy, 'AI', 'Binaries/archives'],
    ];
    return Row(
      children: cards.asMap().entries.map((entry) {
        final i = entry.key;
        final c = entry.value;
        return Expanded(
          child: Container(
            margin: EdgeInsets.only(left: i == 0 ? 0 : 6),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: cardBg,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                  color: isDark
                      ? const Color(0xFF30363D)
                      : Colors.grey[200]!),
            ),
            child: Column(
              children: [
                Icon(c[0] as IconData,
                    color: accentColor, size: 18),
                const SizedBox(height: 4),
                Text(c[1] as String,
                    style: TextStyle(
                        color: isDark
                            ? Colors.white
                            : Colors.black87,
                        fontWeight: FontWeight.bold,
                        fontSize: 10)),
                Text(c[2] as String,
                    style: TextStyle(
                        color: isDark
                            ? const Color(0xFF8B949E)
                            : Colors.grey[500],
                        fontSize: 9)),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }
}