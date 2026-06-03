# Office 像素资源归属

本目录下的像素美术资源（`characters/`、`floors/`、`furniture/`）来自开源项目
**pixel-agents**，按其 MIT 许可证使用：

- 项目：https://github.com/pixel-agents-hq/pixel-agents
- 许可证：MIT License
- 用途：TFA 侧栏「办公室」可视化——每个 tmux 会话渲染为一个像素小人。

帧规格（供渲染参考）：角色精灵表 `char_N.png` 为 112×96，每帧 16×32、每行 7 帧；
行 0/1/2 = 朝下/朝上/朝右（朝左由朝右水平翻转）。每行 7 帧的用途：
walk = 帧 [0,1,2,1]，typing = 帧 [3,4]，reading = 帧 [5,6]。
地板 16×16；DESK_FRONT 48×32；CUSHIONED_CHAIR_FRONT 16×16。

未改动原始像素；仅在 TFA 中按上述规格切帧渲染。
