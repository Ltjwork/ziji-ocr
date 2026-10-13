import 'package:flutter_test/flutter_test.dart';
import 'package:gujichazi/services/ollama_port_reclaim.dart';

void main() {
  group('OllamaPortReclaim.portFromBaseUrl', () {
    test('完整地址取其端口', () {
      expect(OllamaPortReclaim.portFromBaseUrl('http://localhost:11434'), 11434);
      expect(OllamaPortReclaim.portFromBaseUrl('http://192.168.1.5:11435/'), 11435);
    });

    test('没写协议时自动补 http 再解析', () {
      expect(OllamaPortReclaim.portFromBaseUrl('localhost:11434'), 11434);
    });

    test('没写端口/空地址回退 Ollama 默认端口', () {
      expect(OllamaPortReclaim.portFromBaseUrl('http://localhost'), 11434);
      expect(OllamaPortReclaim.portFromBaseUrl('https://ai.example.com'), 11434);
      expect(OllamaPortReclaim.portFromBaseUrl(''), 11434);
      expect(OllamaPortReclaim.portFromBaseUrl('   '), 11434);
    });
  });

  group('OllamaPortReclaim.parseExcludedRanges', () {
    // 中文 Windows netsh 实际输出样例（2026-10-01 实测，保留段恰含 11434）。
    const sample = '''
\n
协议 tcp 端口排除范围

开始端口    结束端口
----------    --------
      3208        3307
     11335       11434
     11522       11621
     50000       50059     *
''';

    test('解析区间行，忽略中文表头/分隔线/空行', () {
      final ranges = OllamaPortReclaim.parseExcludedRanges(sample);
      expect(ranges, hasLength(4));
      expect(ranges[0].start, 3208);
      expect(ranges[0].end, 3307);
      expect(ranges[0].administered, isFalse);
    });

    test('带 * 的行识别为管理员登记的应用保留', () {
      final ranges = OllamaPortReclaim.parseExcludedRanges(sample);
      final starred = ranges.last;
      expect(starred.start, 50000);
      expect(starred.end, 50059);
      expect(starred.administered, isTrue);
    });

    test('含边界值：区间端点算命中，区间外不算', () {
      final ranges = OllamaPortReclaim.parseExcludedRanges(sample);
      final hit = ranges.where((r) => r.contains(11434)).toList();
      expect(hit, hasLength(1));
      expect(hit.single.start, 11335);
      expect(ranges.any((r) => r.contains(11435)), isFalse);
      expect(ranges.any((r) => r.contains(11334)), isFalse);
    });

    test('空输出/纯杂讯返回空列表', () {
      expect(OllamaPortReclaim.parseExcludedRanges(''), isEmpty);
      expect(OllamaPortReclaim.parseExcludedRanges('协议 tcp 端口排除范围\n----\n'), isEmpty);
      expect(OllamaPortReclaim.parseExcludedRanges('abc def ghi\n1 2 3\n99999 100 x'), isEmpty);
    });
  });

  group('OllamaPortHealth 分类', () {
    test('被系统保留（10013）且无应用保留 → 可抢回', () {
      const h = OllamaPortHealth(
        port: 11434,
        bindable: false,
        bindError: OllamaPortReclaim.errorAccessDenied,
        ranges: [ExcludedPortRange(start: 11335, end: 11434)],
      );
      expect(h.reclaimable, isTrue);
      expect(h.hitRange?.start, 11335);
    });

    test('可正常绑定 → 无需抢回', () {
      const h = OllamaPortHealth(port: 11434, bindable: true);
      expect(h.reclaimable, isFalse);
      expect(h.hitRange, isNull);
    });

    test('端口被占用（10048）→ 不走抢回', () {
      const h = OllamaPortHealth(
        port: 11434,
        bindable: false,
        bindError: OllamaPortReclaim.errorInUse,
      );
      expect(h.reclaimable, isFalse);
    });

    test('已在应用保留区间内（管理员登记）→ 不再重复抢回', () {
      const h = OllamaPortHealth(
        port: 11434,
        bindable: false,
        bindError: OllamaPortReclaim.errorAccessDenied,
        ranges: [ExcludedPortRange(start: 11335, end: 11434, administered: true)],
      );
      expect(h.reclaimable, isFalse);
    });

    test('被保留但保留区间信息读取失败（ranges 为空）→ 仍允许抢回', () {
      const h = OllamaPortHealth(
        port: 11434,
        bindable: false,
        bindError: OllamaPortReclaim.errorAccessDenied,
      );
      expect(h.reclaimable, isTrue);
    });
  });
}
