# Cloud Mail 部署说明

> 以下为通用步骤。实际域名/邮箱/account_id 由 `setup-and-deploy.sh` 自动检测或首次运行时交互式填写。

## 一键部署

```bash
chmod +x scripts/setup-and-deploy.sh
./scripts/setup-and-deploy.sh
```

脚本流程：`wrangler login` → 自动检测/创建 D1/KV → 写 `wrangler.toml` → 设置 `jwt_secret`（云端已有则跳过） → 构建前端并 deploy。

**首次运行**会交互式询问邮件域名和管理员邮箱，之后写入 `wrangler.toml` 本地保存（已 gitignore）。

## 部署后必做

### 1. 初始化数据库

首次部署后，浏览器打开（JWT 在 `.local-secrets.env`）：

```text
https://<worker>.<subdomain>.workers.dev/api/init/<JWT_SECRET>
```

或绑定自定义域后用你的域名。

### 2. Email Routing Catch-all → Worker

Dashboard → 你的域名 → **Email Routing** → **Catch-all**：

- 操作：**Send to a Worker**
- Worker：`cloud-mail`
- 启用

或 CLI（需 API Token + Zone ID）：

```bash
source .local-secrets.env
curl -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/email/routing/rules/catch_all" \
  -H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" \
  -H "Content-Type: application/json" \
  --data '{"matchers":[{"type":"all"}],"actions":[{"type":"worker","value":["cloud-mail"]}],"enabled":true,"name":"cloud-mail"}'
```

### 3. 注册管理员

打开站点，用你设定的管理员邮箱注册并登录。

### 4. 发信（可选）

1. 注册 [Resend](https://resend.com)，添加域名并完成 DNS
2. 创建 API Key
3. 后台系统设置填入 Key
4. Webhook：`https://<你的域>/api/webhooks`

### 5. 附件 / R2（可选）

Dashboard 开通 **R2** 后：

```bash
npx wrangler r2 bucket create cloud-mail
```

在 `mail-worker/wrangler.toml` 取消 `r2_buckets` 注释并重新 deploy。

## 验证

1. 向 `test@<你的域>` 发信 → 后台收件箱可见
2. （配置 Resend 后）后台发信 → 对方收到

## 仅登录 Wrangler

```bash
cd mail-worker
npx wrangler login
npx wrangler whoami
```
