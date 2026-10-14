import 'dart:ui';

/// 行内单字彩虹色板：同一行内每个单字按行内序号（order）循环取色——
/// 字框填充/描边与对应文字（chips、整行文字）使用同一颜色，方便对照
/// "哪个框画得多大 ↔ 哪个文字"。原定义在 editor_page，抽出共享给
/// 直读对照字片（direct_text_panel）等复用同一套颜色语义。
const List<Color> kCharRainbow = [
  Color(0xFFE53935), // red
  Color(0xFFFB8C00), // orange
  Color(0xFFF9A825), // yellow
  Color(0xFF43A047), // green
  Color(0xFF00897B), // teal
  Color(0xFF039BE5), // light blue
  Color(0xFF3949AB), // indigo
  Color(0xFF8E24AA), // purple
];

Color charRainbowColor(int index) => kCharRainbow[index % kCharRainbow.length];
