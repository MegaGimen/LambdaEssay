import 'dart:ui_web' as ui_web;

void registerViewFactory(String viewId, dynamic cb) {
  ui_web.platformViewRegistry.registerViewFactory(viewId, cb);
}
