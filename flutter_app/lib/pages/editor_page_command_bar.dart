part of 'editor_page.dart';

/// 编辑器顶部命令栏（菜单 + Word 式工具栏）的控制器：动作组按当前
/// 页面状态逐帧构造（enabled/checked/visible 全部就地取材），布局
///（分组顺序/显隐/组名开关）由 [_EditorPageState._toolbarSettings]
/// 决定并持久化。本文件是 editor_page.dart 的 part，直接访问其私有
/// 状态——动作定义离不开页内几十个字段与方法，收进 part 避免主文件
/// 继续膨胀。
class _EditorCommandBarController {
  _EditorCommandBarController(this.s);

  final _EditorPageState s;

  EditorToolbarSettings get settings => s._toolbarSettings;

  /// 自定义对话框的每次修改都即时落盘并刷新（对话框后的工具栏实时
  /// 预览，关闭即完成）。
  Future<void> updateSettings(EditorToolbarSettings next) async {
    await next.save();
    if (!s.mounted) return;
    s.cmdSetState(() => s._toolbarSettings = next);
  }

  void openCustomize() {
    showEditorToolbarCustomizeDialog(
      s.context,
      groups: groups(),
      settings: settings,
      onChanged: (next) => unawaited(updateSettings(next)),
    );
  }

  // ── 拖拽摆位（吸附落点松手即存）──

  /// 任一按钮/组正在被拖拽：页面据此把空 dock 也渲染成可落点的占位框
  ///（否则拖进还没有内容的左/右/底部工具栏无处可放）。
  final ValueNotifier<bool> dragActive = ValueNotifier(false);

  void dispose() {
    dragActive.dispose();
  }

  void _onDragStarted(EditorDragPayload _) => dragActive.value = true;

  void _onDragEnded() => dragActive.value = false;

  /// 按钮落入 [toGroup] 的 [beforeActionId] 之前（null = 追加到组尾）。
  /// 落点规则（含拖进空白 dock 时把「自定义」组登记进落点栏）统一在
  /// applyActionDrop，控制器只负责取定义与落盘。
  void _onMoveAction(
    EditorActionDragPayload payload,
    String toGroup,
    String? beforeActionId, {
    String? dockHint,
  }) {
    unawaited(
      updateSettings(
        applyActionDrop(
          settings,
          groups(),
          payload,
          toGroup: toGroup,
          beforeActionId: beforeActionId,
          dockHint: dockHint,
        ),
      ),
    );
  }

  /// 空白 dock 占位框的落点：带 dock 信息（见 [EditorEmptyDockPlaceholder]）。
  void _onMoveActionToDock(
    EditorActionDragPayload payload,
    String toGroup,
    String? beforeActionId,
    String dock,
  ) {
    _onMoveAction(payload, toGroup, beforeActionId, dockHint: dock);
  }

  /// 整组移到 [toDock] 的 [beforeGroupId] 之前（null = 该栏末尾）。
  void _onMoveGroup(String groupId, String toDock, String? beforeGroupId) {
    final defaults = [for (final g in groups()) g.id];
    unawaited(
      updateSettings(
        settings.withGroupMoved(
          groupId,
          toDock,
          beforeGroupId,
          currentDocksFull: {
            for (final d in EditorToolbarDocks.all)
              d: settings.groupsInDock(d, defaults),
          },
        ),
      ),
    );
  }

  /// 后台控制台视图不显示命令栏与各 dock。
  Widget build() {
    if (s._viewIndex != 0) return const SizedBox.shrink();
    return EditorCommandBar(
      groups: groups(),
      settings: settings,
      onOpenCustomize: openCustomize,
      onDragStarted: _onDragStarted,
      onDragEnded: _onDragEnded,
      onMoveAction: _onMoveAction,
      onMoveActionToDock: _onMoveActionToDock,
      onMoveGroup: _onMoveGroup,
    );
  }

  /// 左/右/底部 dock 的渲染入口：有内容渲染工具栏；拖拽中渲染空白
  /// 落点占位；平时无内容不占空间。
  Widget dockWidget(String dock) {
    if (s._viewIndex != 0) return const SizedBox.shrink();
    final laidOut = applyToolbarLayout(settings, groups());
    final dockGroups = laidOut[dock] ?? const <EditorActionGroup>[];
    if (dockGroups.isNotEmpty) {
      return EditorDockBar(
        dock: dock,
        groups: dockGroups,
        settings: settings,
        onDragStarted: _onDragStarted,
        onDragEnded: _onDragEnded,
        onMoveAction: _onMoveAction,
        onMoveGroup: _onMoveGroup,
      );
    }
    if (dragActive.value) {
      return EditorEmptyDockPlaceholder(
        dock: dock,
        onMoveAction: _onMoveActionToDock,
        onMoveGroup: _onMoveGroup,
      );
    }
    return const SizedBox.shrink();
  }

  /// 「自定义」组被引用时注入定义（菜单行多出「自定义」列、布局可解析）。
  List<EditorActionGroup> groups() {
    final pageBusy = s._loading || s._annotation == null;
    final result = [
      // ── 页面：摆正 / 旋转镜像 / 识别方向 / 引擎 / 删除 ──
      EditorActionGroup(
        id: 'page',
        label: '页面',
        actions: [
          EditorAction(
            id: 'straighten',
            label: '摆正',
            icon: Icons.crop_free,
            tooltip: '校对摆正：智能检测裁切点，透视拉平书页（可去色/锐化）',
            enabled: !s._loading,
            onPressed: () => unawaited(s._openStraighten()),
          ),
          _pageOp('rotate_cw', '顺转90°', Icons.rotate_right, '顺时针旋转 90°（标注几何同步变换）'),
          _pageOp('rotate_ccw', '逆转90°', Icons.rotate_left, '逆时针旋转 90°（标注几何同步变换）'),
          _pageOp('flip_h', '左右镜像', Icons.swap_horiz, '左右镜像（标注几何同步变换）'),
          _pageOp('flip_v', '上下镜像', Icons.swap_vert, '上下镜像（标注几何同步变换）',
              trailingSeparator: true),
          EditorAction(
            id: 'page_orientation',
            label: '识别方向',
            icon: Icons.screen_rotation_alt,
            tooltip: '本页识别方向：排版方向与阅读方向可按页单独设置',
            enabled: !pageBusy,
            onPressed: () => unawaited(s._showPageOrientationDialog()),
          ),
          EditorAction(
            id: 'engine_settings',
            label: '识别引擎',
            icon: Icons.auto_awesome_outlined,
            tooltip: '识别引擎（本书）：Kraken / PaddleOCR 切换与 Paddle 模型档位',
            enabled: !pageBusy,
            onPressed: () => unawaited(s._showEngineSettingsDialog()),
          ),
          EditorAction(
            id: 'delete_page',
            label: '删除该页',
            icon: Icons.delete_outline,
            tooltip: '删除该页：删除图片与本页标注，后页编号前移',
            danger: true,
            enabled: !pageBusy,
            onPressed: () => unawaited(s._confirmDeletePage()),
          ),
        ],
      ),
      // ── 全书：总览 / 叠加 / 主区快设 / 拆分 / 全书归类 / 整本识别 / 插件 ──
      EditorActionGroup(
        id: 'book',
        label: '全书',
        actions: [
          _bookOp('book_grid', '总览', Icons.grid_view, '全书总览：网格浏览所有页（可切主区/段/行/字层），点击跳页',
              () => unawaited(s._openBookGrid())),
          _bookOp('book_overlay', '叠加', Icons.layers, '全书叠加：所有页半透明叠加，批量调整并应用正文区',
              () => unawaited(s._openBookOverlay())),
          _bookOp('region_grid', '主区快设', Icons.filter_center_focus,
              '主区快设：网格逐页快速框正文区，改完统一按主区拆行/字/段',
              () => unawaited(s._openBookRegionGrid())),
          _bookOp('book_split', '拆分', Icons.splitscreen, '跨页拆分：左右两页合扫的书按中缝拆成两页',
              () => unawaited(s._openBookSplit())),
          _bookOp('similar_book', '全书归类', Icons.auto_stories,
              '墨迹归类（全书版）：指定页范围或整本书跨页聚类批量校正',
              () => unawaited(s._openSimilarCharsBook())),
          _bookOp('recognize_book', '整本识别', Icons.play_circle_outline,
              '开始整本识别：后台逐页识别无标注的页，完成后回到书库看进度',
              () => s._startWholeBookRecognition()),
          for (final entry in PluginHost.instance.enabledEntries(
            projectDir: s.widget.project.projectDir,
          ))
            EditorAction(
              id: 'plugin:${entry.pluginId}:${entry.entryKey}',
              label: entry.title,
              icon: entry.iconData,
              tooltip: entry.subtitle ?? entry.title,
              enabled: !s._loading,
              onPressed: () => unawaited(s._openPluginEntry(entry)),
            ),
        ],
      ),
      // ── 视图：视图模式 / 整页文本 / 序号 / 字框 ──
      EditorActionGroup(
        id: 'view',
        label: '视图',
        actions: [
          EditorAction(
            id: 'view_mode',
            label: '视图模式',
            icon: Icons.view_week,
            tooltip: '切换标注视图：主区 / 段 / 行 / 详细',
            // 复合动作本体不点击：菜单里渲染为展开项，工具栏是分段控件。
            enabled: false,
            onPressed: null,
            ribbonBody: (ctx) => SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'region', label: Text('主区')),
                ButtonSegment(value: 'paragraph', label: Text('段')),
                ButtonSegment(value: 'line', label: Text('行')),
                ButtonSegment(value: 'char', label: Text('详细')),
              ],
              selected: s._viewMode == 'text' ? const <String>{} : {s._viewMode},
              // 文本视图无对应分段：允许空选中（否则断言崩溃）
              emptySelectionAllowed: true,
              onSelectionChanged: (sel) {
                if (sel.isEmpty || s._reorderMode) return;
                s.cmdSetState(() => s._viewMode = sel.first);
              },
            ),
            menuItems: [
              for (final mode in const [
                ('region', '主区视图'),
                ('paragraph', '段视图'),
                ('line', '行视图'),
                ('char', '详细（单字）视图'),
                ('text', '整页文本（直读）'),
              ])
                EditorMenuItemSpec(
                  label: mode.$2,
                  checked: s._viewMode == mode.$1,
                  onPressed: () => s.cmdSetState(() {
                    if (s._reorderMode) return;
                    s._viewMode = mode.$1;
                  }),
                ),
            ],
          ),
          EditorAction(
            id: 'text_view',
            label: '整页文本',
            icon: Icons.notes,
            tooltip: '整页文本（直读）：整页识别文字连成一篇直接读校',
            checked: s._viewMode == 'text',
            enabled: !s._reorderMode,
            onPressed: () => s.cmdSetState(
              () => s._viewMode = s._viewMode == 'text' ? 'line' : 'text',
            ),
          ),
          EditorAction(
            id: 'show_index',
            label: '序号',
            icon: Icons.format_list_numbered,
            tooltip: '显示序号：画布上标注主区/段/行/字的编号',
            checked: s._showIndex,
            onPressed: () => s.cmdSetState(() => s._showIndex = !s._showIndex),
          ),
          EditorAction(
            id: 'show_char_box',
            label: '字框',
            icon: Icons.crop_square,
            tooltip: '显示字框：详细视图在行图上勾出每个字框',
            checked: s._showCharBox,
            onPressed: () => s.cmdSetState(() => s._showCharBox = !s._showCharBox),
          ),
        ],
      ),
      // ── 主区：新框类别（仅主区视图）/ 层级推断 ──
      EditorActionGroup(
        id: 'region',
        label: '主区',
        actions: [
          EditorAction(
            id: 'region_labels',
            label: '新框类别',
            icon: Icons.style,
            tooltip: '新画主区框的类别（快捷键 1~8；段/行视图选非正文类别时拖拽直接画该版面框）',
            // 常显：切到段/行/详细等视图不隐藏（用户要求），类别选择
            // 随时可见；段/行视图选非正文类别时拖拽即画该版面框。
            onPressed: null,
            ribbonBody: (ctx) => Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < RegionLabel.all.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: Tooltip(
                      message: '新画框用此类别（快捷键 ${i + 1}；段/行视图选非正文类别时拖拽直接画该版面框）',
                      child: ChoiceChip(
                        avatar: Container(
                          width: 9,
                          height: 9,
                          decoration: BoxDecoration(
                            color: RegionLabel.color(RegionLabel.all[i]),
                            shape: BoxShape.circle,
                          ),
                        ),
                        label: Text(
                          '${RegionLabel.displayName(RegionLabel.all[i])} ${i + 1}',
                          style: const TextStyle(fontSize: 12),
                        ),
                        selected: s._newRegionLabel == RegionLabel.all[i],
                        visualDensity: VisualDensity.compact,
                        showCheckmark: false,
                        onSelected: (_) => s.cmdSetState(
                          () => s._newRegionLabel = RegionLabel.all[i],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            menuItems: [
              for (var i = 0; i < RegionLabel.all.length; i++)
                EditorMenuItemSpec(
                  label:
                      '${RegionLabel.displayName(RegionLabel.all[i])} ${i + 1}',
                  colorDot: RegionLabel.color(RegionLabel.all[i]),
                  checked: s._newRegionLabel == RegionLabel.all[i],
                  onPressed: () => s.cmdSetState(
                    () => s._newRegionLabel = RegionLabel.all[i],
                  ),
                ),
            ],
          ),
          EditorAction(
            id: 'infer_hierarchy',
            label: '层级推断',
            icon: Icons.account_tree,
            tooltip: '自动推断层级：按几何包含关系重排 主区→段→行→字 的归属',
            enabled: s._annotation != null,
            onPressed: () {
              final ann = s._annotation;
              if (ann == null) return;
              s.cmdSetState(
                () => ann.inferHierarchy(
                  orientation: s._pageOrientation,
                  horizontalDir: s._pageSettings.horizontalDir,
                  verticalDir: s._pageSettings.verticalDir,
                  force: true,
                  // 画布已解码图像：主区（行外接矩形+2%边距）钳回图片范围
                  imageWidth: s._canvasImageSize.width.round(),
                  imageHeight: s._canvasImageSize.height.round(),
                ),
              );
              s._save();
            },
          ),
        ],
      ),
      // ── 校对：排序 / 合并模式（详细视图）/ 墨迹归类 / 墨迹校验 / 重新识别 ──
      EditorActionGroup(
        id: 'proof',
        label: '校对',
        actions: [
          EditorAction(
            id: 'reorder',
            label: s._reorderMode
                ? '取消排序'
                : s._viewMode == 'region' || s._viewMode == 'char'
                ? '行排序'
                : '点击排序',
            icon: s._reorderMode ? Icons.close : Icons.touch_app,
            tooltip: '排序模式：按阅读顺序点击行/段，点满后提交（Esc 取消）',
            checked: s._reorderMode,
            enabled: !s._loading,
            onPressed: () => s._reorderMode
                ? s._cancelReorderMode()
                : s._enterReorderMode(),
          ),
          EditorAction(
            id: 'merge_mode',
            label: '合并模式',
            icon: Icons.merge_type,
            tooltip: '单字识别模式：普通 / 合并 / 智能（合并后全书同类批量应用）',
            // 常显：切视图不隐藏；模式只在详细（单字）视图参与交互，
            // 其他视图下切换仅改状态、下次进详细视图生效。
            onPressed: null,
            ribbonBody: (ctx) => SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'normal', label: Text('普通')),
                ButtonSegment(value: 'merge', label: Text('合并')),
                ButtonSegment(value: 'smart', label: Text('智能')),
              ],
              selected: {
                s._smartMergeMode
                    ? 'smart'
                    : s._mergeMode
                    ? 'merge'
                    : 'normal',
              },
              onSelectionChanged: (sel) => _setMergeMode(sel.first),
            ),
            menuItems: [
              EditorMenuItemSpec(
                label: '普通模式',
                checked: !s._mergeMode && !s._smartMergeMode,
                onPressed: () => _setMergeMode('normal'),
              ),
              EditorMenuItemSpec(
                label: '合并模式',
                checked: s._mergeMode && !s._smartMergeMode,
                onPressed: () => _setMergeMode('merge'),
              ),
              EditorMenuItemSpec(
                label: '智能模式（合并/分割后全书同类墨迹批量应用）',
                checked: s._smartMergeMode,
                onPressed: () => _setMergeMode('smart'),
              ),
            ],
          ),
          EditorAction(
            id: 'similar_chars',
            label: '墨迹归类',
            icon: Icons.hub_outlined,
            tooltip: '墨迹归类：本页相似字块分组批量校正，组可确认；页内可进全书版',
            enabled: !pageBusy,
            onPressed: () => unawaited(s._openSimilarChars()),
          ),
          EditorAction(
            id: 'verify_chars',
            label: '墨迹校验',
            icon: Icons.fact_check_outlined,
            tooltip: '墨迹校验：识别文字与原字墨迹重叠比对，不匹配的标红并转待复核',
            enabled: !pageBusy && !s._verifyingPage && !s._boxReviewing,
            onPressed: () => unawaited(s._verifyPageChars()),
          ),
          EditorAction(
            id: 'reseg_page',
            label: '重新识别',
            icon: Icons.refresh,
            tooltip: '重新识别当前页：重跑整页识别（现有标注被覆盖）',
            enabled: !s._loading,
            onPressed: () => s._loadPage(forceSegment: true),
          ),
        ],
      ),
      // ── AI：检查识别框 / 溯源 ──
      EditorActionGroup(
        id: 'ai',
        label: 'AI',
        actions: [
          EditorAction(
            id: 'box_review',
            label: 'AI 查框',
            icon: Icons.auto_fix_high,
            tooltip: 'AI 检查识别框：扫描可疑行（重叠/高框/低置信度/两路分歧/'
                '墨迹存疑），重摆后按识别置信度裁决，提升才采纳；需在 AI 辅助设置中开启',
            enabled: !pageBusy && !s._boxReviewing && !s._verifyingPage,
            onPressed: () => unawaited(s._runBoxReviewPage()),
          ),
          EditorAction(
            id: 'ai_trace',
            label: 'AI 溯源',
            icon: Icons.manage_history,
            tooltip: 'AI 溯源：回看本页最后一次识别的完整 AI 辅助过程——'
                '每行 AI 看到的图、提示词、思考过程、判定依据、写入内容与 YOLO 局部修复前后',
            enabled: !pageBusy,
            onPressed: () => unawaited(
              showAiTracePanel(
                s.context,
                projectDir: s.widget.project.projectDir,
                pageId: s._pageId,
                pageLabel: '第 ${s._pageIndex + 1} 页',
              ),
            ),
          ),
        ],
      ),
      // ── 保存：临时 / 确认识别框 / 确认并保存 ──
      EditorActionGroup(
        id: 'save',
        label: '保存',
        actions: [
          EditorAction(
            id: 'save_draft',
            label: '临时保存',
            icon: s._dirty ? Icons.save : Icons.save_outlined,
            tooltip: '临时保存：保存当前修改（未完成也可存），不确认、不计入训练数据',
            enabled: !pageBusy,
            onPressed: () => unawaited(s._saveDraftPage()),
          ),
          EditorAction(
            id: 'save_boxes',
            label: '确认识别框',
            icon: Icons.done_all_outlined,
            tooltip: '确认识别框：确认本页全部识别框几何（正文区/段落/行/字框，'
                '计入检测训练），单字文字候选保持待确认',
            enabled: !pageBusy,
            onPressed: () => unawaited(s._saveBoxesOnlyPage()),
          ),
          EditorAction(
            id: 'save_confirm',
            label: '确认保存',
            icon: Icons.task_alt,
            tooltip: '确认并保存：确认本页全部识别框与文字，计入训练数据',
            enabled: !pageBusy,
            onPressed: () => unawaited(s._saveCurrentPage()),
          ),
        ],
      ),
      // ── 导出：数据集 / 全文 / 框选 Excalidraw ──
      EditorActionGroup(
        id: 'export',
        label: '导出',
        actions: [
          EditorAction(
            id: 'export_dataset',
            label: '导出数据集',
            icon: Icons.storage,
            tooltip: '导出数据集（训练用）：YOLO / CRNN / 识字数据包 / 阅读顺序',
            onPressed: () => Navigator.push(
              s.context,
              MaterialPageRoute(
                builder: (_) => ExportPage(project: s.widget.project),
              ),
            ),
          ),
          EditorAction(
            id: 'export_fulltext',
            label: '导出全文',
            icon: Icons.description_outlined,
            tooltip: '导出全文：整本书按自然段合并为一个 MD / TXT / Word 文件',
            onPressed: () => unawaited(
              TextExportDialog.show(s.context, s.widget.project),
            ),
          ),
          EditorAction(
            id: 'excalidraw_pick',
            label: '框选导出',
            icon: Icons.draw_outlined,
            tooltip: '框选导出 Excalidraw：框选区域，在工作台预览调参后导出可编辑图形',
            checked: s._excalidrawPicking,
            enabled: !pageBusy,
            onPressed: () => s._toggleExcalidrawPick(),
          ),
        ],
      ),
    ];
    // 「自定义」组被引用（dock 登记过，或名下登记过动作——修复前
    // 拖丢的按钮走自愈口径）时注入定义，让布局解析与菜单行都能看到它。
    if (settingsUseCustomGroup(settings)) {
      result.add(
        const EditorActionGroup(
          id: kCustomGroupId,
          label: kCustomGroupLabel,
          actions: [],
        ),
      );
    }
    return result;
  }

  /// 页面几何操作（旋转/镜像）：同一包参数复用四条动作。
  EditorAction _pageOp(
    String id,
    String label,
    IconData icon,
    String tooltip, {
    bool trailingSeparator = false,
  }) => EditorAction(
    id: id,
    label: label,
    icon: icon,
    tooltip: tooltip,
    enabled: !s._loading,
    trailingSeparator: trailingSeparator,
    onPressed: () => unawaited(s._transformCurrentPage(id)),
  );

  /// 全书级操作：进入即可用（无需当前页已识别）。
  EditorAction _bookOp(
    String id,
    String label,
    IconData icon,
    String tooltip,
    VoidCallback onPressed,
  ) => EditorAction(
    id: id,
    label: label,
    icon: icon,
    tooltip: tooltip,
    enabled: !s._loading,
    onPressed: onPressed,
  );

  void _setMergeMode(String mode) {
    s.cmdSetState(() {
      s._mergeMode = mode != 'normal';
      s._smartMergeMode = mode == 'smart';
      s._mergeFirstBox = null;
      s._multiSelectedChars.clear();
      s._selected = null;
    });
    final label = switch (mode) {
      'smart' => '智能模式（合并/分割后全书同类墨迹批量应用）',
      'merge' => '合并模式',
      _ => '普通模式',
    };
    s._snack('已切换到 $label');
  }
}
