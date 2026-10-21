# Notes — Agentic Çalışma ve Proje Kuralları (`GEMINI.md`)

Bu proje macOS üzerinde çalışan, Rust ile yazılmış, **local-first**, **uçtan uca şifreli (E2EE)** ve **self-hosted Cloud API senkronizasyon** destekli Notion benzeri bir not alma uygulamasıdır.

## 1. İletişim ve Koordinasyon Kuralları
- Kullanıcıyla aksi belirtilmedikçe **Türkçe**, net ve öz iletişim kur.
- **Ana Oturum (Coordinator) Kuralı:** Hangi chat ortamında (Antigravity, Claude Code, Codex vb.) başlatılırsa başlatılsın, ana oturum **Koordinatördür (Coordinator)**.
- **Yapılan her geliştirme alt ajanlarla (subagents) yapılır.** Koordinatör doğrudan uygulama kodu yazmaz; işi parçalar, uygun alt ajanı çağırır, doğrulama/inceleme kapılarını (gates) işletir ve Git işlemlerini yönetir.

## 2. Alt Ajanlar (Subagents) ve Model Eşleşmesi

Tüm alt ajanlar `.agents/agents/*.md` altında tanımlıdır ve aşağıdaki model katmanlarıyla çalıştırılır:

| Rol | Dosya | Model Parametresi (`Model`) | Hedef Model | Yetki / Görev |
| :--- | :--- | :--- | :--- | :--- |
| **`explorer`** | `.agents/agents/explorer.md` | `flash` | Gemini 3.8 Flash | Salt okunur (Read-Only). Dosya, sembol, bağımlılık ve kod keşfi. |
| **`coder`** | `.agents/agents/coder.md` | `flash` | Gemini 3.8 Flash | Yazma yetkili. Mimari plana göre Rust kodu ve birim testlerin yazılması. |
| **`architect`** | `.agents/agents/architect.md` | `pro` | Gemini 4 Argon | Salt okunur (Kod yazmaz). Sistem mimarisi, şifreleme protokolü, veri şeması ve API kontrat tasarımı. |
| **`reviewer`** | `.agents/agents/reviewer.md` | `pro` | Gemini 4 Argon | Salt okunur (Read-Only). Kod kalitesi, Rust güvenliği, kriptografi ve mimari uyumluluk denetimi. |

### Ortamlara Göre Başlatma (Multi-Environment Trigger)
- **Antigravity İçinden:** `invoke_subagent` aracıyla `TypeName: "<explorer|coder|architect|reviewer>"` ve tabloya uygun `Model: "flash"` veya `Model: "pro"` parametresi açıkça (explicit) verilerek başlatılır.
- **Claude Code / Codex / CLI Ortamlarından:** `.claude/agents/*.md`, `.codex/agents/*.toml` veya `.claude/progress/lib.sh` içindeki `run_subagent <role> <task> <prompt_file>` yardımcısıyla aynı model eşleşmesi (`flash` / `pro`) korunarak başlatılır.

## 3. Geliştirme İş Akışı (Workflow Pipeline)

Her yeni özellik veya değişiklik şu sırayı takip eder:
1. **Keşif (`explorer` — `flash`):** Mevcut kod tabanı veya ilgili modüller taranır (`dosya:satır` özeti çıkarılır).
2. **Tasarım (`architect` — `pro`):** Yeni bir sistem, veri modeli, şifreleme akışı veya 2+ modülü etkileyen bir değişiklikse `architect` mimari kontratı ve `coder` iş paketlerini çıkarır.
3. **Geliştirme (`coder` — `flash`):** Atanan dosya kapsamında (disjoint write scope) kodu ve testleri yazar, `cargo check` ve `cargo test` çalıştırır. Paralel çalışan iki `coder` asla aynı dosyaya dokunmaz.
4. **Denetim (`reviewer` — `pro`):** Yazılan kodu mimari, kriptografi ve Rust standartları açısından inceler. Bulgular varsa düzeltme için tekrar `coder` ajanına yönlendirilir.
5. **Kabul ve Git (`Coordinator`):** Alt ajanlar asla `git add/commit/branch/checkout/merge/push` çalıştırmaz. Koordinatör testleri ve review onayını doğruladıktan sonra commit alır.
