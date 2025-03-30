import 'dart:collection';
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
  _BrowserState createState() => _BrowserState();
}

class _BrowserState extends State<Browser> with SingleTickerProviderStateMixin {
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
  late Offset _velocity; // 添加速度变量
  final double moveStep = 10.0; // 每次移动的步长

  late AnimationController _animationController;
  late Animation<Offset> _animation;

  final FocusNode textFieldFocusNode = FocusNode(); // 添加 FocusNode

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

    // 监听遥控器按键事件
    RawKeyboard.instance.addListener(_handleKeyEvent);
  }

  @override
  void dispose() {
    _animationController.dispose();
    textFieldFocusNode.dispose();
    RawKeyboard.instance.removeListener(_handleKeyEvent);
    super.dispose();
  }

  void _handleKeyEvent(RawKeyEvent event) {
    if (event is RawKeyDownEvent) {
      setState(() {
        Offset newTargetPosition = targetMousePosition;
        if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
          _velocity = Offset(0, -moveStep); // 设置向上的速度
        } else if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
          _velocity = Offset(0, moveStep); // 设置向下的速度
        } else if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
          _velocity = Offset(-moveStep, 0); // 设置向左的速度
        } else if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
          _velocity = Offset(moveStep, 0); // 设置向右的速度
        } else if (event.logicalKey == LogicalKeyboardKey.select) {
          _simulateMouseClick();
        } else if (event.logicalKey == LogicalKeyboardKey.goBack ||
            event.logicalKey == LogicalKeyboardKey.escape) {
          webViewController?.goBack();
        }

        // 根据速度计算新的目标位置
        newTargetPosition = targetMousePosition + _velocity;

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
      });
    }
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
    return WillPopScope(
      onWillPop: () async {
        if (webViewController != null) {
          bool canGoBack = await webViewController!.canGoBack();
          if (canGoBack) {
            webViewController?.goBack();
            return false; // 阻止退出
          }
        }
        return false; // 还是不允许退出
      },
      child: Scaffold(
        appBar: AppBar(title: Text("InAppWebView")),
        body: SafeArea(
          child: Stack(
            children: [
              Column(
                children: <Widget>[
                  TextField(
                    focusNode: textFieldFocusNode, // 绑定 FocusNode
                    decoration: InputDecoration(prefixIcon: Icon(Icons.search)),
                    controller: urlController,
                    keyboardType: TextInputType.text,
                    onSubmitted: (value) {
                      var url = WebUri(value);
                      if (url.scheme.isEmpty) {
                        url = WebUri(
                          (!kIsWeb
                                  ? "https://www.google.com/search?q="
                                  : "https://www.bing.com/search?q=") +
                              value,
                        );
                      }
                      webViewController?.loadUrl(
                        urlRequest: URLRequest(url: url),
                      );
                    },
                  ),
                  Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque, // 确保点击事件传递到子组件
                      onTap: () {
                        // 确保点击页面时 TextField 不会获取焦点
                        textFieldFocusNode.unfocus();
                      },
                      child: Stack(
                        children: [
                          InAppWebView(
                            key: webViewKey,
                            webViewEnvironment: webViewEnvironment,
                            initialUrlRequest: URLRequest(
                              url: WebUri('https://google.com'),
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
                left: mousePosition.dx - 5,
                top: mousePosition.dy - 5,
                child: IgnorePointer(
                  ignoring: true, // 允许点击事件透传
                  child: Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.red, width: 2), // 空心圆边框
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
}
