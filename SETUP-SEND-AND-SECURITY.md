# 发信（Resend）+ 安全加固

> 以下为通用步骤，域名/邮箱以 `<你的域>` / `<管理员邮箱>` 代替。实际值见本地 `wrangler.toml`。

---

## C. 安全加固（先做）

### C1. 关闭公开注册（后台或 SQL）

**后台：** 系统设置 → 注册相关 → **关闭开放注册**

**或命令：**

```bash
cd mail-worker
npx wrangler d1 execute cloud-mail --remote \
  --command "UPDATE setting SET register = 1;"
```

（`register = 1` 表示关闭；`0` 为开放）

### C2. jwt_secret 改为 Secret（去掉配置明文）

`wrangler.toml` 里已去掉 `jwt_secret` 明文。首次部署时脚本会自动设置。如需手动操作：

```bash
cd mail-worker

# 生成并写入 Secret（仅首次，已有则跳过）
printf '%s' "$(openssl rand -hex 32)" | npx wrangler secret put jwt_secret
```

注意：

- 轮换 jwt 后，**已登录会话会失效**，用管理员重新登录即可。
- 若 `keep_vars = true` 导致线上仍保留旧 plain `jwt_secret`，在 Dashboard → Workers → cloud-mail → Settings → Variables 里 **删除** 名为 `jwt_secret` 的普通变量，只保留 Secret。

### C3. 管理员密码

登录后在个人设置里改成强密码。

### C4. （可选）Turnstile 防刷

Cloudflare Dashboard → Turnstile 创建站点 → 把 site key / secret 填进 Cloud Mail 系统设置。

---

## B. 发信（Resend）

### B1. 注册并验证域名

1. 打开 https://resend.com 注册并登录
2. **Domains** → **Add Domain** → 填 `<你的域>`
3. Resend 会给出 DNS 记录（常见为）：
   - 若干 **TXT**（SPF / 域名验证）
   - 若干 **CNAME**（DKIM，如 `resend._domainkey`）
4. 到 Cloudflare DNS 按页面 **原样添加**
   - CNAME 建议 **DNS only（灰云）**，不要橙云代理
5. 回到 Resend 点 **Verify**，等到状态 **Verified**

### B2. 创建 API Key

Resend → **API Keys** → Create → 复制（只显示一次）

### B3. 填进 Cloud Mail

1. 打开你的站点
2. 管理员登录 → **系统设置**
3. 找到 **Resend** / 发信 Token
4. 为域名填入 API Key 并保存
5. 确认 **发信** 开关为开启

### B4. Webhook（可选，看发送状态）

Resend → Webhooks → 添加：

```text
https://<你的域>/api/webhooks
```

按文档勾选投递/失败等事件。

### B5. 测试发信

1. 后台写新邮件
2. 发件人选管理员邮箱
3. 发到你自己的外部邮箱
4. 能收到 = 发信成功

---

## 验收清单

- [ ] 未登录无法随意注册新用户（注册已关）
- [ ] `wrangler secret list` 能看到 `jwt_secret`
- [ ] Dashboard 变量里没有明文 `jwt_secret`
- [ ] Resend 域名 Verified
- [ ] 后台能发出邮件到外部邮箱
- [ ] 收信正常

---

## 常见问题

| 现象 | 处理 |
|------|------|
| 发信失败 / unauthorized | Resend Key 或域名未 Verified |
| 进垃圾箱 | 等 DKIM/SPF 生效；避免一上来群发 |
| 登录全部失效 | 正常（jwt 轮换后）；重新登录 |
| 仍能注册 | 确认 `register=1` 或后台关掉注册 |
