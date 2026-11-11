package protocol

// Public application constants observed on com.phoenix.read 7.3.9.32.
// They are app identity, not a copied device credential.
const (
	Package        = "com.phoenix.read"
	VersionName    = "7.3.9.32"
	VersionCode    = "73932"
	AID            = "8662"
	AppName        = "novelread"
	DevicePlatform = "android"

	// OfficialSignatureHash 是红果官方安装包的签名摘要（注册端用于判断
	// 客户端真伪）。这是公开的包标识，不是凭据。
	OfficialSignatureHash = "56a962410c494bbaf0b58dba20cae56f"
	// RegisterUA 是注册接口使用的 UA（与读取接口的 UA 不同：不带 Cronet 段）。
	RegisterUA = Package + "/72232 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3)"

	// 取流链路的客户端版本：POST 批量接口用 74332（上游 6.6），
	// video_tab 兜底 GET 用 71332（上游 6.7）。UA 与签名内版本必须同步。
	PlaybackVersionName = "7.4.3.32"
	PlaybackVersionCode = "74332"
	PlaybackUserAgent   = Package + "/74332 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)"

	// video_tab 兜底 GET 用 73932（与注册 body 的版本资料一致）。
	VideoTabVersionName = "7.3.9.32"
	VideoTabVersionCode = "73932"
	// video_tab 的 UA 沿用抓包里的 71332（与 query 的 73932 版本不同，上游实测接受）。
	VideoTabUserAgent = Package + "/71332 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)"

	// APIHost 同时服务片库读取与取流。2026-11 起取流只认 b 域名
	// （api5-normal-sinfonlineb）；a 域名对取流返回 200 + 空 body，
	// 对搜索/详情仍正常，所以统一走 b。
	APIHost = "api5-normal-sinfonlineb.fqnovel.com"
	// RegisterHost 是匿名设备注册入口。2026-11 起官方客户端用 lf 域名，
	// 注册出的身份才会被取流接口接受。
	RegisterHost = "log5-applog-lf.fqnovel.com"

	PathDiscover   = "/reading/bookapi/bookmall/tab/v"
	PathCellChange = "/reading/bookapi/bookmall/cell/change/v"
	PathSearch     = "/reading/bookapi/search/tab/v"
	PathSeries     = "/novel/player/video_detail/v1/"
	// PathSeriesBatch is the player's batch detail read (multi_video_detail,
	// player scene; observed 2026-10-24).
	PathSeriesBatch     = "/novel/player/multi_video_detail/player/v1"
	PathPlayback        = "/novel/player/video_model/v1/"
	// PathMultiPlayback 是播放器批量取流接口（2026-11-10 起上游 6.6 的入口）。
	PathMultiPlayback = "/novel/player/multi_video_model/v1/"
	// PathVideoTabPlayback 是取流的签名 GET 兜底入口，POST 返回空时使用。
	PathVideoTabPlayback = "/reading/bookapi/video_tab/multi_video_model/v1/"
	PathAlbum           = "/novel/player/album_detail/v1/"
	PathSuggest         = "/reading/bookapi/search/suggest/v1/"
	PathCue             = "/reading/bookapi/search/cue/v1/"
	PathCategory        = "/reading/bookapi/new_category/front/v1/"
	PathCategoryLanding = "/reading/bookapi/new_category/landing/v1/"
	PathRank            = "/reading/ugc/rank_book/get/v1/"
	PathPlan            = "/reading/bookapi/plan/v1/"
	PathRankActivity    = "/novel/reading/activity_api/get_rank_activity/v1/"
	PathRankCells       = "/reading/bookapi/bookmall/cell/change/v1/"
	// PathSubscribeList serves the 上新 calendar (tab_type 5); PathProfile
	// and PathUserWorks a person's page and their works (observed 2026-10-24).
	PathSubscribeList = "/reading/user/subscribe/list/v1/"
	PathProfile       = "/reading/user/profile/get/v1/"
	PathUserWorks     = "/novel/commentapi/user/profile/%s/v1"
	// DefaultRankCell is the bookmall cell the 经典 channel serves for the
	// ranking page (observed: algo 179 推荐榜).
	DefaultRankCell = "7224069876808155173"
	// ShortRankCell is the bookmall cell behind the short-drama ranking page
	// (tab_type 26); cell/change on it serves every content and list.
	ShortRankCell = "7470092475068071998"
	// PathShortFilter is the short-drama filter page (筛选). The reading host
	// answers 404; it lives on DistributionHost.
	PathShortFilter = "/reading/distribution/category/landpage/v1/"
	// DistributionHost serves the /reading/distribution/ and activity_api
	// families. It is APIHost; it stays separate so APIOrigin can point at
	// reading.snssdk.com, which answers 404 for them.
	DistributionHost = APIHost
	// DefaultRankActivity and DefaultRankList are the hard-coded ids of the
	// 星粉榜 activity in the shipped client.
	DefaultRankActivity = "hongguo_actor_fans_ranklist_activity"
	DefaultRankList     = "hongguo_actor_fans_ranklist"
	PathRegister        = "/service/2/device_register/"

	SearchTabShortPlay = "11"
	// Search tabs filled by an anonymous search response.
	// SeriesVideo is 剧集, PugcVideo is 视频, Discussion is 讨论,
	// Common is 小说, HgUser is 用户, and Voice is 听书.
	SearchTabSeriesVideo = "29"
	SearchTabPugcVideo   = "30"
	SearchTabDiscussion  = "31"
	SearchTabCommon      = "1"
	SearchTabHgUser      = "27"
	SearchTabVoice       = "2"
	// SearchSourceHome is the home-search first page (search_source=1, tab_name=feed).
	SearchSourceHome = "1"
	SearchTabName    = "feed"
)

// CredentialHeaderNames are account credentials. Anonymous search does not send them.
// A guest cookie from this installation and lc=101 are not account credentials.
var CredentialHeaderNames = []string{
	"Authorization",
	"X-Tt-Token",
	"Openid",
}
