import 'dart:collection';
import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:mywww/main.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

class Browser extends StatefulWidget {
  const Browser({super.key});

  @override
  BrowserState createState() => BrowserState();
}

class BrowserState extends State<Browser> with SingleTickerProviderStateMixin {
  final GlobalKey webViewKey = GlobalKey();

  InAppWebViewController? webViewController;
  InAppWebViewSettings settings = InAppWebViewSettings(
    isInspectable: kDebugMode,
    mediaPlaybackRequiresUserGesture: false,
    allowsInlineMediaPlayback: true,
    iframeAllow: "camera; microphone",
    iframeAllowFullscreen: true,
    disableInputAccessoryView: true, // 禁用输入附件视图（iOS）
  );

  PullToRefreshController? pullToRefreshController;

  String url = "";
  double progress = 0;
  final urlController = TextEditingController();

  Offset mousePosition = Offset(200, 200);
  Offset targetMousePosition = Offset(200, 200);
  late Offset _velocity;
  final double moveStep = 8.0;

  late AnimationController _animationController;
  late Animation<Offset> _animation;

  final FocusNode textFieldFocusNode = FocusNode();

  Timer? _longPressTimer; // 定时器，用于处理长按超过半秒后的持续移动
  Timer? _speedIncreaseTimer; // 定时器，用于增加速度
  double _currentAccelerationFactor = 1.0; // 当前加速因子
  bool _isLongPressActive = false; // 标记长按是否激活
  bool _isKeyPressed = false; // 标记按键是否被按下

  bool _isEditing = false; // 标记是否处于编辑状态
  String _labelText = "https://google.com"; // Label 显示的文本

  List<String> _favorites = []; // 收藏的网址列表

  String? _favoritesFilePath; // 收藏文件路径

  @override
  void initState() {
    super.initState();

    _initializeFavoritesFilePath(); // 初始化收藏文件路径
    _loadFavoritesFromDisk(); // 启动时加载收藏列表

    _velocity = Offset.zero; // 初始化速度
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 100), // 动画持续时间
    );

    _animation = Tween<Offset>(
      begin: mousePosition,
      end: targetMousePosition,
    ).animate(
      CurvedAnimation(
        parent: _animationController,
        curve: Curves.easeOutQuad, // 使用更平滑的曲线
      ),
    )..addListener(() {
      setState(() {
        mousePosition = _animation.value; // 更新鼠标位置
      });
    });

    pullToRefreshController =
        kIsWeb ||
                ![
                  TargetPlatform.iOS,
                  TargetPlatform.android,
                ].contains(defaultTargetPlatform)
            ? null
            : PullToRefreshController(
              settings: PullToRefreshSettings(color: Colors.blue),
              onRefresh: () async {
                if (defaultTargetPlatform == TargetPlatform.android) {
                  webViewController?.reload();
                } else if (defaultTargetPlatform == TargetPlatform.iOS) {
                  webViewController?.loadUrl(
                    urlRequest: URLRequest(
                      url: await webViewController?.getUrl(),
                    ),
                  );
                }
              },
            );

    HardwareKeyboard.instance.addHandler(
      _handleKeyEvent,
    ); // 使用 HardwareKeyboard 添加事件处理
  }

  @override
  void dispose() {
    _longPressTimer?.cancel(); // 释放长按定时器
    _speedIncreaseTimer?.cancel(); // 释放速度增加定时器
    _animationController.dispose();
    textFieldFocusNode.dispose();
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent); // 移除事件处理
    super.dispose();
  }

  Future<void> _initializeFavoritesFilePath() async {
    final directory = await getApplicationDocumentsDirectory(); // 获取平台支持的文档目录
    setState(() {
      _favoritesFilePath = '${directory.path}/favorites.json'; // 设置收藏文件路径
    });
  }

  bool _handleKeyEvent(KeyEvent event) {
    if (event is KeyDownEvent) {
      if (!_isKeyPressed &&
          (event.logicalKey == LogicalKeyboardKey.arrowUp ||
              event.logicalKey == LogicalKeyboardKey.arrowDown ||
              event.logicalKey == LogicalKeyboardKey.arrowLeft ||
              event.logicalKey == LogicalKeyboardKey.arrowRight)) {
        _isKeyPressed = true; // 标记按键被按下
        _isLongPressActive = false; // 重置长按激活状态

        // 执行原来的移动一步逻辑
        setState(() {
          _updateVelocity(event.logicalKey);
          _updateTargetPosition();
        });

        // 启动定时器，半秒后激活长按持续移动
        _longPressTimer = Timer(const Duration(milliseconds: 500), () {
          _isLongPressActive = true;
          _startContinuousMovement();
        });
      }

      setState(() {
        if (event.logicalKey == LogicalKeyboardKey.arrowUp ||
            event.logicalKey == LogicalKeyboardKey.arrowDown ||
            event.logicalKey == LogicalKeyboardKey.arrowLeft ||
            event.logicalKey == LogicalKeyboardKey.arrowRight) {
          _updateVelocity(event.logicalKey); // 更新速度
        } else if (event.logicalKey == LogicalKeyboardKey.select) {
          _simulateMouseClick(); // 保留 select 按键逻辑
        }
      });
    } else if (event is KeyUpEvent &&
        (event.logicalKey == LogicalKeyboardKey.arrowUp ||
            event.logicalKey == LogicalKeyboardKey.arrowDown ||
            event.logicalKey == LogicalKeyboardKey.arrowLeft ||
            event.logicalKey == LogicalKeyboardKey.arrowRight)) {
      _isKeyPressed = false; // 按键释放时重置标记
      _isLongPressActive = false; // 停止长按激活状态
      _longPressTimer?.cancel(); // 停止长按定时器
      _speedIncreaseTimer?.cancel(); // 停止速度增加定时器
      _velocity = Offset.zero; // 停止移动
    }
    return false; // 返回 false 表示未拦截事件
  }

  void _startContinuousMovement() {
    if (_isLongPressActive) {
      _currentAccelerationFactor = 1.0; // 重置加速因子
      _speedIncreaseTimer = Timer.periodic(const Duration(milliseconds: 500), (
        timer,
      ) {
        if (!_isLongPressActive) {
          timer.cancel(); // 停止定时器
          return;
        }
        setState(() {
          _currentAccelerationFactor += 0.5; // 每半秒增加加速因子
        });
      });

      Timer.periodic(const Duration(milliseconds: 50), (timer) {
        if (!_isLongPressActive) {
          timer.cancel(); // 停止定时器
          _speedIncreaseTimer?.cancel(); // 停止速度增加定时器
          return;
        }
        setState(() {
          _updateTargetPosition(); // 持续更新目标位置
        });
      });
    }
  }

  void _updateVelocity(LogicalKeyboardKey key) {
    double currentMoveStep = moveStep * _currentAccelerationFactor; // 使用动态加速因子

    if (key == LogicalKeyboardKey.arrowUp) {
      _velocity = Offset(0, -currentMoveStep); // 设置向上的速度
    } else if (key == LogicalKeyboardKey.arrowDown) {
      _velocity = Offset(0, currentMoveStep); // 设置向下的速度
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      _velocity = Offset(-currentMoveStep, 0); // 设置向左的速度
    } else if (key == LogicalKeyboardKey.arrowRight) {
      _velocity = Offset(currentMoveStep, 0); // 设置向右的速度
    }
  }

  void _updateTargetPosition() {
    Offset newTargetPosition = targetMousePosition + _velocity;

    // 获取屏幕尺寸
    final screenSize = MediaQuery.of(context).size;

    // 限制目标位置在屏幕范围内，包括 AppBar 区域
    newTargetPosition = Offset(
      newTargetPosition.dx.clamp(0, screenSize.width),
      newTargetPosition.dy.clamp(
        0,
        screenSize.height + kToolbarHeight,
      ), // 允许移动到 AppBar 区域
    );

    // 更新目标位置并启动动画
    if (newTargetPosition != targetMousePosition) {
      targetMousePosition = newTargetPosition;
      _animation = Tween<Offset>(
        begin: mousePosition,
        end: targetMousePosition,
      ).animate(
        CurvedAnimation(
          parent: _animationController,
          curve: Curves.easeOutQuad, // 使用更平滑的曲线
        ),
      );
      _animationController.forward(from: 0.0);
    }
  }

  Future<bool> _handlePop() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('确认退出？'),
            content: const Text('确认要对退出吗?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('确定'),
              ),
            ],
          ),
    );
    return confirm ?? false; // 用户点击确定时返回true
  }

  void _simulateMouseClick() {
    final appBarHeight = kToolbarHeight; // AppBar 的标准高度
    Offset globalMousePosition = Offset(
      mousePosition.dx,
      mousePosition.dy + appBarHeight,
    );
    PointerEvent downPointer = PointerDownEvent(
      pointer: 1,
      position: globalMousePosition,
    );
    GestureBinding.instance.handlePointerEvent(downPointer);
    PointerEvent upPointer = PointerUpEvent(
      pointer: 1,
      position: globalMousePosition,
    );
    GestureBinding.instance.handlePointerEvent(upPointer);
  }

  Future<void> _loadFavoritesFromDisk() async {
    if (_favoritesFilePath == null) {
      await _initializeFavoritesFilePath(); // 等待路径初始化完成
    }
    try {
      final file = File(_favoritesFilePath!);
      if (await file.exists()) {
        final content = await file.readAsString();
        final List<dynamic> jsonList = jsonDecode(content);
        setState(() {
          _favorites = jsonList.cast<String>(); // 加载收藏列表
        });
      }
    } catch (e) {
      if (kDebugMode) {
        print("Failed to load favorites: $e");
      }
    }
  }

  Future<void> _saveFavoritesToDisk() async {
    if (_favoritesFilePath == null) return; // 确保路径已初始化
    try {
      final file = File(_favoritesFilePath!);
      await file.writeAsString(jsonEncode(_favorites)); // 保存收藏列表到文件
    } catch (e) {
      if (kDebugMode) {
        print("Failed to save favorites: $e");
      }
    }
  }

  void _addToFavorites(String url) {
    setState(() {
      if (!_favorites.contains(url)) {
        _favorites.add(url); // 添加到收藏列表
        _saveFavoritesToDisk(); // 保存到磁盘
      }
    });
  }

  void _toggleFavorite(String url) {
    setState(() {
      if (_favorites.contains(url)) {
        _favorites.remove(url); // 取消收藏
      } else {
        _favorites.add(url); // 添加到收藏列表
      }
      _saveFavoritesToDisk(); // 更新磁盘存储
    });
  }

  bool _isFavorite(String url) {
    return _favorites.contains(url); // 判断是否已收藏
  }

  void _loadFromFavorites(String url) {
    setState(() {
      _labelText = url; // 更新 Label 文本
      urlController.text = url;
    });
    webViewController?.loadUrl(urlRequest: URLRequest(url: WebUri(url)));
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return; // 已处理弹出则直接返回

        if (_isEditing) {
          setState(() {
            _isEditing = false;
          });
          return;
        }

        bool canGoBack = await webViewController!.canGoBack();
        if (canGoBack) {
          webViewController?.goBack();

          return;
        }

        final allowed = await _handlePop();
        if (allowed && mounted) {
          if (context.mounted) {
            exit(0);
          }
        }
      },
      child: Scaffold(
        appBar: AppBar(title: Text("InAppWebView")),
        body: SafeArea(
          child: Stack(
            children: [
              Column(
                children: <Widget>[
                  Row(
                    children: [
                      Expanded(
                        child: GestureDetector(
                          onTap: () {
                            setState(() {
                              _isEditing = true; // 切换到编辑状态
                              textFieldFocusNode.requestFocus();
                            });
                          },
                          child:
                              _isEditing
                                  ? TextField(
                                    focusNode:
                                        textFieldFocusNode, // 绑定 FocusNode
                                    decoration: InputDecoration(
                                      border: OutlineInputBorder(), // 添加边框
                                    ),
                                    controller: urlController,
                                    autofocus: true, // 自动获取焦点
                                    onSubmitted: (value) {
                                      _submitUrl(value);
                                    },
                                  )
                                  : Container(
                                    width: double.infinity, // 设置宽度为 100%
                                    padding: const EdgeInsets.all(8.0),
                                    decoration: BoxDecoration(
                                      border: Border.all(
                                        color: Colors.grey,
                                      ), // 添加边框
                                      borderRadius: BorderRadius.circular(4.0),
                                    ),
                                    child: Text(
                                      _labelText,
                                      style: const TextStyle(fontSize: 16.0),
                                    ),
                                  ),
                        ),
                      ),
                      IconButton(
                        icon: Icon(
                          Icons.favorite,
                          color:
                              _isFavorite(_labelText)
                                  ? Colors.red
                                  : Colors.grey, // 未收藏时显示灰色
                        ),
                        onPressed: () {
                          _toggleFavorite(_labelText); // 切换收藏状态
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                _isFavorite(_labelText)
                                    ? "已收藏: $_labelText"
                                    : "已取消收藏: $_labelText",
                              ),
                            ),
                          );
                        },
                      ),
                      IconButton(
                        icon: Icon(Icons.list),
                        onPressed: () {
                          showModalBottomSheet(
                            context: context,
                            builder: (context) {
                              return ListView(
                                children:
                                    _favorites.map((url) {
                                      return ListTile(
                                        title: Text(url),
                                        onTap: () {
                                          Navigator.pop(context); // 关闭底部弹窗
                                          _loadFromFavorites(url); // 加载收藏的网址
                                        },
                                      );
                                    }).toList(),
                              );
                            },
                          );
                        },
                      ),
                    ],
                  ),
                  Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque, // 确保点击事件传递到子组件
                      onTap: () {
                        textFieldFocusNode
                            .unfocus(); // 确保点击页面时 TextField 不会获取焦点
                      },
                      child: Stack(
                        children: [
                          InAppWebView(
                            key: webViewKey,
                            webViewEnvironment: webViewEnvironment,
                            initialUrlRequest: URLRequest(
                              url: WebUri(_labelText),
                            ),
                            initialUserScripts:
                                UnmodifiableListView<UserScript>([]),
                            initialSettings: settings,
                            pullToRefreshController: pullToRefreshController,
                            onWebViewCreated: (controller) async {
                              webViewController = controller;
                            },
                            onLoadStart: (controller, url) {
                              setState(() {
                                this.url = url.toString();
                                urlController.text = this.url;
                                _labelText = this.url; // 更新 Label 文本
                              });
                            },
                            onPermissionRequest: (controller, request) {
                              return Future.value(
                                PermissionResponse(
                                  resources: request.resources,
                                  action: PermissionResponseAction.GRANT,
                                ),
                              );
                            },
                            shouldOverrideUrlLoading: (
                              controller,
                              navigationAction,
                            ) async {
                              var uri = navigationAction.request.url!;

                              if (![
                                "http",
                                "https",
                                "file",
                                "chrome",
                                "data",
                                "javascript",
                                "about",
                              ].contains(uri.scheme)) {
                                if (await canLaunchUrl(uri)) {
                                  // Launch the App
                                  await launchUrl(uri);
                                  // and cancel the request
                                  return NavigationActionPolicy.CANCEL;
                                }
                              }

                              return NavigationActionPolicy.ALLOW;
                            },
                            onLoadStop: (controller, url) {
                              pullToRefreshController?.endRefreshing();
                              setState(() {
                                this.url = url.toString();
                                urlController.text = this.url;
                              });
                            },
                            onReceivedError: (controller, request, error) {
                              pullToRefreshController?.endRefreshing();
                            },
                            onProgressChanged: (controller, progress) {
                              if (progress == 100) {
                                pullToRefreshController?.endRefreshing();
                              }
                              setState(() {
                                this.progress = progress / 100;
                                urlController.text = url;
                              });
                            },
                            onUpdateVisitedHistory: (
                              controller,
                              url,
                              isReload,
                            ) {
                              setState(() {
                                this.url = url.toString();
                                urlController.text = this.url;
                              });
                            },
                            onConsoleMessage: (controller, consoleMessage) {
                              //print(consoleMessage);
                            },
                          ),
                          progress < 1.0
                              ? LinearProgressIndicator(value: progress)
                              : Container(),
                        ],
                      ),
                    ),
                  ),
                  OverflowBar(
                    alignment: MainAxisAlignment.center,
                    children: <Widget>[
                      ElevatedButton(
                        child: Icon(Icons.arrow_back),
                        onPressed: () {
                          webViewController?.goBack();
                        },
                      ),
                      ElevatedButton(
                        child: Icon(Icons.arrow_forward),
                        onPressed: () {
                          webViewController?.goForward();
                        },
                      ),
                      ElevatedButton(
                        child: Icon(Icons.refresh),
                        onPressed: () {
                          webViewController?.reload();
                        },
                      ),
                    ],
                  ),
                ],
              ),
              Positioned(
                left: mousePosition.dx - 8,
                top: mousePosition.dy - 8,
                child: IgnorePointer(
                  ignoring: true, // 允许点击事件透传
                  child: Container(
                    width: 16,
                    height: 16,
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.red, width: 6), // 空心圆边框
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _submitUrl(String value) {
    setState(() {
      _isEditing = false; // 退出编辑状态
      _labelText = value; // 更新 Label 文本
    });
    var url = WebUri(value);
    if (url.scheme.isEmpty) {
      url = WebUri(
        (!kIsWeb
                ? "https://www.google.com/search?q="
                : "https://www.bing.com/search?q=") +
            value,
      );
    }
    webViewController?.loadUrl(urlRequest: URLRequest(url: url));
  }
}
