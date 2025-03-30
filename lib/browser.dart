import 'dart:collection';
import 'dart:async';
import 'dart:io';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:mywww/main.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter/services.dart';

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
  final double moveStep = 10.0;

  late AnimationController _animationController;
  late Animation<Offset> _animation;

  final FocusNode textFieldFocusNode = FocusNode();

  Timer? _longPressTimer; // 定时器，用于处理长按超过半秒后的持续移动
  bool _isLongPressActive = false; // 标记长按是否激活
  bool _isKeyPressed = false; // 标记按键是否被按下

  bool _isEditing = false; // 标记是否处于编辑状态
  String _labelText = "https://google.com"; // Label 显示的文本

  @override
  void initState() {
    super.initState();

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
    _animationController.dispose();
    textFieldFocusNode.dispose();
    HardwareKeyboard.instance.removeHandler(_handleKeyEvent); // 移除事件处理
    super.dispose();
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
      _velocity = Offset.zero; // 停止移动
    }
    return false; // 返回 false 表示未拦截事件
  }

  void _startContinuousMovement() {
    if (_isLongPressActive) {
      Timer.periodic(const Duration(milliseconds: 50), (timer) {
        if (!_isLongPressActive) {
          timer.cancel(); // 停止定时器
          return;
        }
        setState(() {
          _updateTargetPosition(); // 持续更新目标位置
        });
      });
    }
  }

  void _updateVelocity(LogicalKeyboardKey key) {
    double currentMoveStep =
        _isKeyPressed ? moveStep * (_isLongPressActive ? 1.5 : 1.0) : moveStep;

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

    // 限制目标位置在屏幕范围内
    newTargetPosition = Offset(
      newTargetPosition.dx.clamp(0, screenSize.width),
      newTargetPosition.dy.clamp(0, screenSize.height),
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

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        // 修改为 onPopInvokedWithResult [[1]][[2]]
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
                  GestureDetector(
                    onTap: () {
                      setState(() {
                        _isEditing = true; // 切换到编辑状态
                        textFieldFocusNode.requestFocus();
                      });
                    },
                    child:
                        _isEditing
                            ? Row(
                              children: [
                                Expanded(
                                  child: TextField(
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
                                  ),
                                ),
                                TextButton(
                                  onPressed: () {
                                    _submitUrl(urlController.text);
                                  },
                                  child: const Text("确定"),
                                ),
                              ],
                            )
                            : Container(
                              width: double.infinity, // 设置宽度为 100%
                              padding: const EdgeInsets.all(8.0),
                              decoration: BoxDecoration(
                                border: Border.all(color: Colors.grey), // 添加边框
                                borderRadius: BorderRadius.circular(4.0),
                              ),
                              child: Text(
                                _labelText,
                                style: const TextStyle(fontSize: 16.0),
                              ),
                            ),
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
