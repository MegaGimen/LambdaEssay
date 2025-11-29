import 'dart:html' as html;
import 'dart:ui_web' as ui_web;

void registerPdfViewFactory(
  String viewType,
  html.Element Function(int viewId) factory,
) {
  ui_web.platformViewRegistry.registerViewFactory(viewType, factory);
}
