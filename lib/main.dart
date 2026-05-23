import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'package:vater/src/platform_menu.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:vater/venom_layout.dart';
import 'package:xterm/xterm.dart';
import 'package:window_manager/window_manager.dart';

Future<void> main() async {
  // Initialize Flutter bindings first to ensure the binary messenger is ready
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize window manager for desktop controls
  await windowManager.ensureInitialized();

  WindowOptions windowOptions = const WindowOptions(
    size: Size(720, 620),
    center: true,
    titleBarStyle: TitleBarStyle.hidden,
  );

  windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
  });
  runApp(MyApp());
}

bool get isDesktop {
  if (kIsWeb) return false;
  return [
    TargetPlatform.windows,
    TargetPlatform.linux,
    TargetPlatform.macOS,
  ].contains(defaultTargetPlatform);
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: AppPlatformMenu(child: Home()),
    );
  }
}

class Home extends StatefulWidget {
  Home({super.key});

  @override
  // ignore: library_private_types_in_public_api
  _HomeState createState() => _HomeState();
}

class TerminalTab {
  final String id;
  String title;
  late final Terminal terminal;
  late final TerminalController terminalController;
  late final ScrollController scrollController;
  late final Pty pty;
  bool isInitialized = false;

  TerminalTab({required this.id, this.title = 'Terminal'}) {
    terminal = Terminal(maxLines: 10000);
    terminalController = TerminalController();
    scrollController = ScrollController();
  }

  void init() {
    if (isInitialized) return;
    isInitialized = true;

    pty = Pty.start(
      shell,
      columns: terminal.viewWidth,
      rows: terminal.viewHeight,
    );

    pty.output
        .cast<List<int>>()
        .transform(Utf8Decoder())
        .listen(terminal.write);

    pty.exitCode.then((code) {
      terminal.write('the process exited with exit code $code');
    });

    terminal.onOutput = (data) {
      pty.write(const Utf8Encoder().convert(data));
    };

    terminal.onResize = (w, h, pw, ph) {
      pty.resize(h, w);
    };
  }

  void dispose() {
    scrollController.dispose();
    // pty.kill(); // Optional: kill process when tab closes
  }
}

class _HomeState extends State<Home> {
  final List<TerminalTab> _tabs = [];
  int _activeTabIndex = 0;

  @override
  void initState() {
    super.initState();
    _addNewTab();
  }

  void _addNewTab() {
    setState(() {
      final newTab = TerminalTab(
        id: DateTime.now().toString(),
        title: 'VaTer ${_tabs.length + 1}',
      );
      _tabs.add(newTab);
      _activeTabIndex = _tabs.length - 1;
    });

    // Initialize after frame to ensure layout for dimensions (though Pty.start might not strictly need it immediately if we use defaults, but following original pattern)
    WidgetsBinding.instance.endOfFrame.then((_) {
      if (mounted && _tabs.isNotEmpty) {
        _tabs.last.init();
      }
    });
  }

  void _closeTab(int index) {
    if (_tabs.length <= 1) return; // Don't close the last tab for now

    setState(() {
      _tabs[index].dispose();
      _tabs.removeAt(index);
      if (_activeTabIndex >= _tabs.length) {
        _activeTabIndex = _tabs.length - 1;
      }
    });
  }

  void _setActiveTab(int index) {
    setState(() {
      _activeTabIndex = index;
    });
  }

  @override
  Widget build(BuildContext context) {
    final activeTab = _tabs[_activeTabIndex];

    return VenomScaffold(
      title: 'vater',
      customTitle: Row(
        children: [
          NeonActionBtn(
            onTap: _addNewTab,
            child: Icon(Icons.add, color: Colors.white, size: 18),
          ),
          SizedBox(width: 8),
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: _tabs.length,
              itemBuilder: (context, index) {
                final tab = _tabs[index];
                final isActive = index == _activeTabIndex;
                return MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: () => _setActiveTab(index),
                    child: Container(
                      margin: EdgeInsets.only(right: 4),
                      padding:
                          EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: isActive
                            // ignore: deprecated_member_use
                            ? Colors.white.withOpacity(0.1)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            tab.title,
                            style: TextStyle(
                              color: isActive ? Colors.white : Colors.white54,
                              fontSize: 12,
                            ),
                          ),
                          SizedBox(width: 8),
                          NeonActionBtn(
                            size: 20, // Smaller size for close button
                            onTap: () => _closeTab(index),
                            colors: const [
                              Colors.transparent,
                              Colors.redAccent,
                              Colors.orangeAccent,
                              Colors.redAccent,
                            ],
                            child: Icon(
                              Icons.close,
                              size: 12,
                              color: Colors.white54,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: AutoScrollTerminalWrapper(
          scrollController: activeTab.scrollController,
          child: TerminalView(
            activeTab.terminal,
            controller: activeTab.terminalController,
            scrollController: activeTab.scrollController,
            autofocus: true,
            backgroundOpacity: 0.0,
          onSecondaryTapDown: (details, offset) async {
            final selection = activeTab.terminalController.selection;
            if (selection != null) {
              final text = activeTab.terminal.buffer.getText(selection);
              activeTab.terminalController.clearSelection();
              await Clipboard.setData(ClipboardData(text: text));
            } else {
              final data = await Clipboard.getData('text/plain');
              final text = data?.text;
              if (text != null) {
                activeTab.terminal.paste(text);
              }
            }
          },
        ),
        ),
      ),
    );
  }
}

String get shell {
  if (Platform.isMacOS || Platform.isLinux) {
    return Platform.environment['SHELL'] ?? 'bash';
  }

  if (Platform.isWindows) {
    return 'cmd.exe';
  }

  return 'sh';
}

class AutoScrollTerminalWrapper extends StatefulWidget {
  final Widget child;
  final ScrollController scrollController;

  const AutoScrollTerminalWrapper({
    super.key,
    required this.child,
    required this.scrollController,
  });

  @override
  State<AutoScrollTerminalWrapper> createState() => _AutoScrollTerminalWrapperState();
}

class _AutoScrollTerminalWrapperState extends State<AutoScrollTerminalWrapper> {
  Timer? _scrollTimer;
  static const double _scrollThreshold = 40.0;
  static const double _scrollAmount = 15.0;

  double? _pointerDy;
  double? _boxHeight;
  int _scrollDirection = 0; // -1 for up, 1 for down, 0 for none

  void _checkScroll() {
    if (_pointerDy == null || _boxHeight == null) return;
    
    if (_pointerDy! < _scrollThreshold) {
      _startScrolling(-1);
    } else if (_pointerDy! > _boxHeight! - _scrollThreshold) {
      _startScrolling(1);
    } else {
      _stopScrolling();
    }
  }

  void _startScrolling(int direction) {
    if (_scrollDirection == direction && _scrollTimer != null) return;
    _stopScrolling();
    _scrollDirection = direction;
    
    _scrollTimer = Timer.periodic(const Duration(milliseconds: 30), (timer) {
      if (!widget.scrollController.hasClients) return;
      final position = widget.scrollController.position;
      
      double target = position.pixels + (_scrollAmount * _scrollDirection);
      target = target.clamp(position.minScrollExtent, position.maxScrollExtent);
      
      if (target != position.pixels) {
        widget.scrollController.jumpTo(target);
      }
    });
  }

  void _stopScrolling() {
    _scrollTimer?.cancel();
    _scrollTimer = null;
    _scrollDirection = 0;
  }

  @override
  void dispose() {
    _stopScrolling();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerMove: (event) {
        if (!event.down) {
          _stopScrolling();
          return;
        }
        final RenderBox? renderBox = context.findRenderObject() as RenderBox?;
        if (renderBox != null) {
          _pointerDy = event.localPosition.dy;
          _boxHeight = renderBox.size.height;
          _checkScroll();
        }
      },
      onPointerUp: (_) {
         _pointerDy = null;
         _stopScrolling();
      },
      onPointerCancel: (_) {
         _pointerDy = null;
         _stopScrolling();
      },
      child: widget.child,
    );
  }
}
