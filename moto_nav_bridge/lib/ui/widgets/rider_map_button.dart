import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../controllers/rider_map_controller.dart';
import '../../l10n/app_text.dart';

class RiderMapButton extends StatelessWidget {
  const RiderMapButton({super.key, required this.dark});
  final bool dark;
  @override
  Widget build(BuildContext context) {
    final riders = context.watch<RiderMapController?>();
    if (riders == null) return const SizedBox.shrink();
    final en = AppText.of(context).isEnglish;
    return Material(
      color: dark ? const Color(0xff121820) : Colors.white,
      shape: const CircleBorder(),
      elevation: 1,
      child: IconButton(
        tooltip: en ? 'Sydney riders' : '悉尼骑友',
        icon: Icon(
          riders.viewing ? Icons.people : Icons.people_outline,
          color: dark ? Colors.white : null,
        ),
        onPressed: () => showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          useSafeArea: true,
          showDragHandle: true,
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
          builder: (_) => ChangeNotifierProvider.value(
            value: riders,
            child: const _RiderSettings(),
          ),
        ),
      ),
    );
  }
}

class _RiderSettings extends StatelessWidget {
  const _RiderSettings();
  @override
  Widget build(BuildContext context) {
    final riders = context.watch<RiderMapController>();
    final en = AppText.of(context).isEnglish;
    return SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                en ? 'Sydney riders' : '悉尼骑友',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              Text(
                en
                    ? 'Only riders who choose to share appear. Viewing does not share your location.'
                    : '只显示自愿共享的骑友。查看地图不会自动公开你的位置。',
              ),
              if (!riders.signedIn)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    en
                        ? 'Sign in under My devices to use this feature.'
                        : '请先在 My devices 登录账号。',
                  ),
                ),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: Text(en ? 'Show riders' : '显示骑友'),
                subtitle: Text(
                  en ? 'Refreshes about every 5 seconds' : '约每 5 秒刷新',
                ),
                value: riders.viewing,
                onChanged: riders.signedIn ? riders.setViewing : null,
              ),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  en ? 'Share my position during navigation' : '导航期间共享我的位置',
                ),
                subtitle: Text(
                  en
                      ? 'Public to signed-in NAVIO users · approximate 100 m grid'
                      : '所有已登录 NAVIO 用户可见 · 约百米网格位置',
                ),
                value: riders.sharing,
                onChanged: !riders.signedIn
                    ? null
                    : (value) async {
                        if (!value) {
                          riders.setSharing(false);
                          return;
                        }
                        final agreed = await showDialog<bool>(
                          context: context,
                          builder: (dialog) => AlertDialog(
                            title: Text(
                              en
                                  ? 'Share your location publicly?'
                                  : '公开共享你的位置？',
                            ),
                            content: Text(
                              en
                                  ? 'Other signed-in users can see your profile photo and follow your approximate live location while you navigate in the Sydney area. No route or destination is shared. Arrival, ending navigation or turning this off withdraws it; network loss may leave a marker visible for up to about 30 seconds. People can copy visible photos or positions. This is off again when the app restarts.'
                                  : '悉尼区域内导航时，其他已登录用户可看到你的个人头像并持续查看近似位置；不共享路线和目的地。到达、结束导航或关闭开关后撤下；网络异常时标记可能保留约 30 秒。可见的头像和位置可能被他人截取保存。重启 App 后默认关闭。',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(dialog, false),
                                child: Text(en ? 'Cancel' : '取消'),
                              ),
                              TextButton(
                                onPressed: () => Navigator.pop(dialog, true),
                                child: Text(en ? 'Agree and share' : '同意并共享'),
                              ),
                            ],
                          ),
                        );
                        if (context.mounted && agreed == true) {
                          riders.setSharing(true);
                        }
                      },
              ),
              if (riders.sharing)
                Text(
                  riders.active
                      ? (en
                            ? 'Sharing when an accurate, fresh location is available.'
                            : '获取到新鲜、准确定位时共享。')
                      : (en
                            ? 'Not sharing now; waiting for active navigation.'
                            : '当前未共享，等待开始导航。'),
                ),
              if (riders.truncated)
                Text(
                  en
                      ? 'Showing up to 500 riders. More riders are online.'
                      : '当前最多显示 500 位骑友，还有更多骑友在线。',
                ),
              if (riders.error != null)
                Text(
                  en
                      ? 'Rider service unavailable. Navigation is unaffected.'
                      : '骑友服务暂不可用，不影响导航。',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
