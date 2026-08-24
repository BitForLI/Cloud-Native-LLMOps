# LLMOps 项目协作规则

## 沟通方式

- 默认使用简体中文，先说结论，再说必要原因。
- 使用通俗、简短的表达；专业术语第一次出现时用一句话解释。
- 用户没有要求详细说明时，避免长篇背景、复杂表格和大量分支方案。
- 指导用户手动操作时，一次只给一个明确步骤，并说明正常结果是什么。
- 可以使用轻松的比喻，但故障、费用和安全问题必须直接、准确，不开玩笑。

## 排错方式

- 先判断问题属于：本地环境、应用代码、Terraform、AWS 实际配置、GitHub Actions、凭证或客户端输入。
- 给出判断时必须说明关键证据；不根据单一截图或猜测直接下结论。
- 优先执行只读检查，再修改代码、重启服务或部署。
- 不要反复让用户等待、重试、重启或重新部署。同一路径失败一次后，下一步应读取日志、状态或实际配置。
- 不重复已经验证过的步骤；先使用当前对话、Git 历史和工作区证据。
- 命令出错时，先判断是命令写法问题还是项目问题，避免把工具错误误判为 AWS 或代码故障。

## 项目事实边界

- 项目定位是 AWS 云原生 LLMOps 平台，不是以聊天界面为核心的应用。
- Dev 环境的同步与异步链路已经真实验证：ALB、ECS API、SQS、Worker、Bedrock 和 DynamoDB。
- Staging 与 Production 主要是仓库中的设计和代码；没有真实部署证据时，不得声称已经上线或验证。
- 项目没有使用 LangChain；通过 `boto3` 直接调用 Bedrock、SQS 和 DynamoDB。
- 当前 API 无会话记忆、无最终用户前端，Dev ALB 使用 HTTP。

## AWS 与安全

- 默认区域是 `ap-southeast-2`，本地 AWS Profile 是 `llmops-new`。
- AU Bedrock inference profile 可能路由到悉尼和墨尔本；排查权限时要同时考虑目标区域、模型协议和 IAM 资源范围。
- 基础设施优先由 Terraform 管理。必须手动修改 AWS 时，要说明原因和 Terraform 漂移风险。
- 不输出、记录或要求用户发送 API Key、AWS Token、密码、MFA 或 Secret 内容。
- 创建持续计费资源前说明主要费用；未经明确授权，不部署 Production、不执行 Terraform destroy。
- Production 尚未配置完成时，Production Drift 和 Production Evaluation 只允许手动触发，不启用定时任务。

## 修改与 Git

- 工作区可能包含用户或先前任务的未提交改动；不得覆盖、回退或顺带提交无关文件。
- 提交时只暂存本次任务涉及的文件，并在推送前检查 staged diff。
- 修改 GitHub Actions 时，同时检查对应的 `.github/tests`，避免工作流与测试约束不一致。
- 不把“本地测试通过”等同于“AWS 已部署成功”；分别报告代码、Terraform、CI 和 AWS 验证结果。

## 验证命令

- Python 全量测试：先设置 `PYTHONPATH=services/api`，再运行：
  `python -m pytest services/api/tests services/worker/tests services/common evals loadtests .github/tests`
- Dev Terraform 测试：
  `.\.tools\terraform.exe -chdir=terraform/environments/dev test`
- 提交前至少运行：
  `git diff --check`
- 涉及 GitHub 工作流并已推送时，确认最新 CI 最终状态，而不只确认它已开始运行。

## 最终回复

- 简短说明：完成了什么、验证结果、仍有什么限制或风险。
- 没有阻塞时，不用列出大量“下一步建议”。
- 发现自己的命令或判断有误时，直接纠正并说明影响，不转移原因。
