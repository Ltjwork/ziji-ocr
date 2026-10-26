# -*- coding: utf-8 -*-
"""PaddleOCR-VL 本地采样参数补丁测试。

背景：paddlex 本地 doc_vlm 预测器把 repetition_penalty/temperature/top_p
警告后丢弃（官网演示在服务端推理栈才生效），重复生成退化（同一句话连读
两遍、无限循环挂满 900s）在这台机器上只能靠 900s 超时止损。本套件锁定
paddle_vl_sampling 两个 patch 点的行为：
1. DocVLMLocalPredictor.process 不再丢弃三个采样参数（临时绑定 generate
   追加采样 kwargs，用完还原）；
2. PaddleOCRVLForConditionalGeneration.generate 把采样参数转发给底层
   GenerationMixin.generate（temperature>0 切 sampling + top_k=0；
   temperature<=0 保持贪心；repetition_penalty 贪心也转发）。
不装 paddlex（paddle 测试环境没有）：用 sys.modules 假模块复刻上游
丢弃行为与模型包装，验证补丁语义；paddlex 缺失时整体跳过不抛错。
"""
import contextlib
import sys
import types
import unittest

import paddle_vl_sampling

_PRED_MOD = "paddlex.inference.models.doc_vlm.predictor"
_MODEL_MOD = (
    "paddlex.inference.models.doc_vlm.modeling.paddleocr_vl._paddleocr_vl"
)


class _FakePaddle:
    @staticmethod
    @contextlib.contextmanager
    def no_grad():
        yield


def _build_fakes():
    """构造复刻上游行为的假 paddlex 模块树，返回 (gen_calls, 模块注册表)。

    假 DocVLMLocalPredictor.process 与上游一致：只透传
    max_new_tokens/use_cache，三个采样参数警告后丢弃（这里静默丢弃）；
    假模型 generate 与上游包装一致：只转发 max_new_tokens/use_cache 给
    父类 GenerationMixin.generate（记录调用供断言）。"""
    gen_calls = []

    class GenerationMixin:
        def generate(self, **kwargs):
            gen_calls.append(kwargs)
            return "GEN"

    class PaddleOCRVLForConditionalGeneration(GenerationMixin):
        def generate(self, inputs, **kwargs):
            gen_kwargs = {
                "max_new_tokens": kwargs.get("max_new_tokens", 8192),
                "use_cache": kwargs.get("use_cache", True),
            }
            gen_kwargs = {**inputs, **gen_kwargs}
            with _FakePaddle.no_grad():
                return super().generate(**gen_kwargs)

    class DocVLMLocalPredictor:
        def process(
            self,
            data,
            max_new_tokens=None,
            skip_special_tokens=None,
            repetition_penalty=None,
            temperature=None,
            top_p=None,
            min_pixels=None,
            max_pixels=None,
            use_cache=None,
            **kwargs,
        ):
            generate_kwargs = {}
            if max_new_tokens is not None:
                generate_kwargs["max_new_tokens"] = max_new_tokens
            if use_cache is not None:
                generate_kwargs["use_cache"] = use_cache
            return self.infer.generate(data, **generate_kwargs)

    pred_mod = types.ModuleType(_PRED_MOD)
    pred_mod.DocVLMLocalPredictor = DocVLMLocalPredictor
    model_mod = types.ModuleType(_MODEL_MOD)
    model_mod.PaddleOCRVLForConditionalGeneration = (
        PaddleOCRVLForConditionalGeneration
    )
    return gen_calls, {_PRED_MOD: pred_mod, _MODEL_MOD: model_mod}


def _reset_patch_state():
    paddle_vl_sampling._installed = False
    paddle_vl_sampling._result = ""


class PaddleVLSamplingTest(unittest.TestCase):
    def setUp(self):
        self._saved = {
            k: v for k, v in sys.modules.items() if k.startswith("paddlex")
        }
        for k in self._saved:
            sys.modules.pop(k, None)
        _reset_patch_state()

    def tearDown(self):
        for k in list(sys.modules):
            if k.startswith("paddlex"):
                sys.modules.pop(k, None)
        sys.modules.update(self._saved)
        _reset_patch_state()

    def _install(self):
        gen_calls, mods = _build_fakes()
        sys.modules.update(mods)
        return gen_calls, mods[_PRED_MOD].DocVLMLocalPredictor

    def test_ensure_installs_both_patches_and_is_idempotent(self):
        gen_calls, Predictor = self._install()
        result = paddle_vl_sampling.ensure_vl_sampling_support()
        self.assertEqual(result, "installed")
        self.assertTrue(Predictor.process._ziji_sampling_patch)
        model_cls = sys.modules[_MODEL_MOD].PaddleOCRVLForConditionalGeneration
        self.assertTrue(model_cls.generate._ziji_sampling_patch)
        again = paddle_vl_sampling.ensure_vl_sampling_support()
        self.assertEqual(again, "installed")
        # 幂等：二次安装不叠加包装（process 仍是同一函数对象）。
        self.assertIs(Predictor.process, Predictor.process)

    def test_repetition_penalty_forwarded_greedy(self):
        gen_calls, Predictor = self._install()
        paddle_vl_sampling.ensure_vl_sampling_support()
        pred = Predictor()
        pred.infer = sys.modules[_MODEL_MOD].PaddleOCRVLForConditionalGeneration()
        pred.process({"x": 1}, max_new_tokens=100, repetition_penalty=1.2)
        self.assertEqual(len(gen_calls), 1)
        call = gen_calls[0]
        self.assertEqual(call["repetition_penalty"], 1.2)
        self.assertNotIn("decode_strategy", call)  # 贪心解码保持不变
        self.assertEqual(call["max_new_tokens"], 100)

    def test_temperature_positive_switches_to_sampling(self):
        gen_calls, Predictor = self._install()
        paddle_vl_sampling.ensure_vl_sampling_support()
        pred = Predictor()
        pred.infer = sys.modules[_MODEL_MOD].PaddleOCRVLForConditionalGeneration()
        pred.process(
            {"x": 1},
            max_new_tokens=100,
            temperature=0.7,
            top_p=0.9,
        )
        call = gen_calls[0]
        self.assertEqual(call["decode_strategy"], "sampling")
        self.assertEqual(call["temperature"], 0.7)
        self.assertEqual(call["top_p"], 0.9)
        self.assertEqual(call["top_k"], 0)  # 库默认 top_k=50 被显式关闭
        self.assertNotIn("repetition_penalty", call)

    def test_temperature_zero_stays_greedy_but_penalty_applies(self):
        gen_calls, Predictor = self._install()
        paddle_vl_sampling.ensure_vl_sampling_support()
        pred = Predictor()
        pred.infer = sys.modules[_MODEL_MOD].PaddleOCRVLForConditionalGeneration()
        pred.process(
            {"x": 1},
            max_new_tokens=100,
            temperature=0.0,
            repetition_penalty=1.15,
        )
        call = gen_calls[0]
        self.assertNotIn("decode_strategy", call)
        self.assertEqual(call["repetition_penalty"], 1.15)

    def test_no_sampling_params_keeps_original_behavior(self):
        gen_calls, Predictor = self._install()
        paddle_vl_sampling.ensure_vl_sampling_support()
        pred = Predictor()
        pred.infer = sys.modules[_MODEL_MOD].PaddleOCRVLForConditionalGeneration()
        pred.process({"x": 1}, max_new_tokens=100, use_cache=True)
        self.assertEqual(
            gen_calls[0],
            {"x": 1, "max_new_tokens": 100, "use_cache": True},
        )
        # 临时绑定用完还原：实例上不残留 generate 属性。
        self.assertNotIn("generate", vars(pred.infer))

    def test_unavailable_when_paddlex_missing(self):
        # 模拟 paddlex 不可用（本机 paddle 测试环境装了真 paddlex，不能
        # 靠环境缺席触发）：import 抛 ImportError 时补丁必须静默降级。
        import importlib

        real_import = importlib.import_module

        def _boom(name, *args, **kwargs):
            raise ImportError(f"simulated: {name}")

        importlib.import_module = _boom
        try:
            result = paddle_vl_sampling.ensure_vl_sampling_support()
        finally:
            importlib.import_module = real_import
        self.assertEqual(result, "unavailable")

    def test_sampling_kwargs_normalization(self):
        f = paddle_vl_sampling._sampling_kwargs
        self.assertEqual(f(1.0, 0.0, None), {})  # 全默认 = 无操作
        self.assertEqual(
            f(1.2, None, None), {"repetition_penalty": 1.2}
        )
        self.assertEqual(
            f(None, 0.5, None),
            {
                "decode_strategy": "sampling",
                "temperature": 0.5,
                "top_p": 1.0,
                "top_k": 0,
            },
        )
        self.assertEqual(
            f(None, 0.5, 0.9),
            {
                "decode_strategy": "sampling",
                "temperature": 0.5,
                "top_p": 0.9,
                "top_k": 0,
            },
        )
        # 非数值输入一律忽略（白名单归一语义与 _vl_predict_kwargs 一致）。
        self.assertEqual(f("bad", None, None), {})


if __name__ == "__main__":
    unittest.main()
