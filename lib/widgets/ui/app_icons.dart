import 'package:flutter/material.dart';

/// 语义图标集（design.md §5.5）。
///
/// 这是全库**唯一**允许出现裸 `Icons.*` 的地方：其余 widget 一律引用本类，
/// 「统一 `_rounded`」与「缺字形图标」这两个问题就只需要在这里保证一次。
///
/// 两条既有结论（`spec/frontend/component-guidelines.md`）：
/// - `Icons.forum` / `Icons.forum_outlined` 在 MaterialIcons 字体里**没有字形**，
///   会渲染成豆腐块；社区入口固定 [community]（`Icons.chat_bubble`）。
/// - 图标变体统一走 `_rounded`：`_outlined` 的描边重量与桌面端观感对不上，
///   混用还会让同一行里的图标粗细不一致。
class AppIcons {
  const AppIcons._();

  // ---- 播放 ----
  static const IconData play = Icons.play_arrow_rounded;
  static const IconData pause = Icons.pause_rounded;
  static const IconData next = Icons.skip_next_rounded;
  static const IconData prev = Icons.skip_previous_rounded;

  // ---- 收藏 / 历史 ----
  static const IconData favorite = Icons.favorite_rounded;
  static const IconData favoriteBorder = Icons.favorite_border_rounded;
  static const IconData history = Icons.history_rounded;

  // ---- 导航 / 入口 ----
  static const IconData search = Icons.search_rounded;
  static const IconData settings = Icons.settings_rounded;
  static const IconData back = Icons.arrow_back_rounded;
  static const IconData chevronRight = Icons.chevron_right_rounded;
  static const IconData community = Icons.chat_bubble;

  // ---- 四个主导航 Tab（顺序即语义：发现 / 随机 / 榜单 / 我的）----
  static const IconData discover = Icons.explore_rounded;
  static const IconData shuffle = Icons.shuffle_rounded;
  static const IconData leaderboard = Icons.leaderboard_rounded;
  static const IconData person = Icons.person_rounded;

  // ---- 下载 / 投屏 ----
  static const IconData download = Icons.download_rounded;
  static const IconData downloaded = Icons.download_done_rounded;
  static const IconData cast = Icons.cast_rounded;

  // ---- 内容入口 / 提示 ----
  static const IconData liveTv = Icons.live_tv_rounded;
  static const IconData category = Icons.category_rounded;
  static const IconData book = Icons.auto_stories_rounded;
  static const IconData newReleases = Icons.new_releases_rounded;
  static const IconData info = Icons.info_rounded;
  static const IconData copy = Icons.copy_rounded;
  static const IconData recordVoiceOver = Icons.record_voice_over_rounded;
  static const IconData store = Icons.storefront_rounded;
  static const IconData bookGuide = Icons.menu_book_rounded;
  static const IconData antenna = Icons.settings_input_antenna_rounded;
  static const IconData notifications = Icons.notifications_active_rounded;
  static const IconData badge = Icons.badge_rounded;
  static const IconData rule = Icons.rule_rounded;
  static const IconData verifiedUser = Icons.verified_user_rounded;
  static const IconData tune = Icons.tune_rounded;
  static const IconData rssFeed = Icons.rss_feed_rounded;
  static const IconData tv = Icons.tv_rounded;

  static const IconData merge = Icons.merge_rounded;
  static const IconData mergeType = Icons.build_rounded;

  // ---- 通用操作 ----
  static const IconData close = Icons.close_rounded;
  static const IconData more = Icons.more_horiz_rounded;
  static const IconData check = Icons.check_rounded;
  static const IconData refresh = Icons.refresh_rounded;
  static const IconData delete = Icons.delete_outline_rounded;
  static const IconData edit = Icons.edit_rounded;
  static const IconData share = Icons.share_rounded;

  // ---- 展开 / 收起 ----
  static const IconData expand = Icons.keyboard_arrow_down_rounded;
  static const IconData collapse = Icons.keyboard_arrow_up_rounded;

  // ---- 播放器 ----
  static const IconData volume = Icons.volume_up_rounded;
  static const IconData speed = Icons.speed_rounded;
  static const IconData subtitle = Icons.subtitles_rounded;
  static const IconData danmaku = Icons.mode_comment_rounded;
  static const IconData fullscreen = Icons.fullscreen_rounded;
  static const IconData fastForward = Icons.fast_forward_rounded;
  static const IconData fastRewind = Icons.fast_rewind_rounded;
  static const IconData brightness = Icons.brightness_6_rounded;

  // ---- 状态与占位 ----
  /// 空态图标（原 `Icons.movie_filter_outlined`）。
  static const IconData empty = Icons.movie_filter_rounded;

  /// 错误态图标（原 `Icons.cloud_off_outlined`）。
  static const IconData error = Icons.cloud_off_rounded;

  /// 封面占位（无 URL / 加载失败）。
  static const IconData coverPlaceholder = Icons.movie_rounded;
  static const IconData coverBroken = Icons.broken_image_rounded;

  // ---- 批次⑤ 长尾归一（≥2 站位的裸图标语义化，rounded 变体）----
  static const IconData deleteSweep = Icons.delete_sweep_rounded;
  static const IconData sort = Icons.sort_rounded;
  // ---- 批次⑤ 长尾归一（rounded 变体语义字段）----
  static const IconData add = Icons.add_rounded;
  static const IconData addLink = Icons.add_link_rounded;
  static const IconData arrowDropDown = Icons.arrow_drop_down_rounded;
  static const IconData arrowForward = Icons.arrow_forward_rounded;
  static const IconData aspectRatio = Icons.aspect_ratio_rounded;
  static const IconData bedtime = Icons.bedtime_rounded;
  static const IconData bookmark = Icons.bookmark_rounded;
  static const IconData bookmarkAdd = Icons.bookmark_add_rounded;
  static const IconData bookmarks = Icons.bookmarks_rounded;
  static const IconData bug = Icons.bug_report_rounded;
  static const IconData castConnected = Icons.cast_connected_rounded;
  static const IconData cleaningServices = Icons.cleaning_services_rounded;
  static const IconData cloudDownload = Icons.cloud_download_rounded;
  static const IconData cookie = Icons.cookie_rounded;
  static const IconData downloading = Icons.downloading_rounded;
  static const IconData editNote = Icons.edit_note_rounded;
  static const IconData errorOutline = Icons.error_outline_rounded;
  static const IconData folder = Icons.folder_open_rounded;
  static const IconData graphicEq = Icons.graphic_eq_rounded;
  static const IconData hd = Icons.hd_rounded;
  static const IconData headset = Icons.headset_rounded;
  static const IconData hourglass = Icons.hourglass_top_rounded;
  static const IconData insights = Icons.insights_rounded;
  static const IconData installDesktop = Icons.install_desktop_rounded;
  static const IconData libraryAdd = Icons.library_add_rounded;
  static const IconData link = Icons.link_rounded;
  static const IconData list = Icons.list_alt_rounded;
  static const IconData memory = Icons.memory_rounded;
  static const IconData menu = Icons.menu_rounded;
  static const IconData myLocation = Icons.my_location_rounded;
  static const IconData qrCode = Icons.qr_code_2_rounded;
  static const IconData qrScanner = Icons.qr_code_scanner_rounded;
  static const IconData radar = Icons.radar_rounded;
  static const IconData replay = Icons.replay_rounded;
  static const IconData save = Icons.save_alt;
  static const IconData swapHoriz = Icons.swap_horiz_rounded;
  static const IconData systemUpdate = Icons.system_update_alt;
  static const IconData timer = Icons.timer_rounded;
  static const IconData touch = Icons.touch_app_rounded;
  static const IconData travelExplore = Icons.travel_explore_rounded;
  static const IconData verified = Icons.verified_rounded;
  static const IconData volumeDown = Icons.volume_down_rounded;
  static const IconData volumeOff = Icons.volume_off_rounded;
}
