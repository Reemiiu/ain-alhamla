#!/bin/bash
# عين الحملة — تحديث مستودع GitHub (Reemiiu/ain-alhamla-db) بالإصدار 4
# 1) ينسخ المستودع في: مشروع التخرج/١_المشروع_الحالي/github_ain-alhamla-db
# 2) يحط فيه القاعدة والتطبيق والموقع والمستندات + README جديد
# 3) يسوي commit ويرفعه (git push). إذا طلب دخول، سجّلي بحساب GitHub حقك.
HERE="$(cd "$(dirname "$0")" && pwd)"                 # مجلد الملفات الجاهزة (فيه README.md)
SRC="$(cd "$HERE/../عين_الحملة_v2" && pwd)"
REPO="$(cd "$HERE/.." && pwd)/github_ain-alhamla-db"
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
set -e
echo "== تحديث GitHub: Reemiiu/ain-alhamla-db =="
if [ ! -d "$REPO/.git" ]; then
  git clone https://github.com/Reemiiu/ain-alhamla-db.git "$REPO"
fi
cd "$REPO"
git pull --ff-only || true
git config user.name  >/dev/null || git config user.name  "Reemiiu"
git config user.email >/dev/null || git config user.email "445220185@tvtc.edu.sa"

# ملفات الإصدار الأول تنتقل إلى legacy/v1
mkdir -p legacy/v1
for f in schema.sql seed.sql schema.dbml; do [ -f "$f" ] && git mv -f "$f" "legacy/v1/$f"; done

RS="rsync -a --delete --exclude .DS_Store"
$RS --exclude legacy "$SRC/database/" database/
$RS --exclude build --exclude .dart_tool --exclude .gradle --exclude '*.log' --exclude .idea --exclude local.properties --exclude .flutter-plugins-dependencies "$SRC/flutter_app/" app/
$RS --exclude download "$SRC/website/" website/
mkdir -p docs
for f in "خطة_عين_الحملة_v4.html" "عرض_عين_الحملة_v4.pptx" "بطاقة_مشروع_عين_الحملة_v4.pdf" "مصفوفة_التكافؤ.md" "نص_المناقشة_الأسبوعية.pdf" "ملاحظات_جلسات_النقاش.md"; do
  [ -f "$SRC/docs/$f" ] && cp "$SRC/docs/$f" docs/
done
cp "$HERE/README.md" README.md
cat > .gitignore <<'EOF'
.DS_Store
**/build/
**/.dart_tool/
**/.gradle/
**/.idea/
**/local.properties
*.apk
*.log
EOF

git add -A
if git diff --cached --quiet; then echo "ما فيه تغييرات جديدة."; else
  git commit -q -m "الإصدار 4: مميزات الحج — 38 جدولاً، التطبيق والموقع ولوحة التحكم، والمستندات

- database: ملفات 01 → 13 (v2، 2.1، v3، v4)، schema.dbml ومخطط ER v4
- app: تطبيق Flutter (الحاج + المشرف، 4 لغات، شاشة حجّي، الخريطة بدون إنترنت) مع android
- website: الموقع التعريفي ولوحة التحكم وقسم الحج (5 صفحات) ونسخة الويب من التطبيق
- docs: الخطة، العرض، البطاقة، مصفوفة التكافؤ، نص المناقشة
- legacy/v1: ملفات الإصدار الأول"
  echo "✅ تم تجهيز التحديث محلياً."
fi
set +e
echo ">> الرفع على GitHub..."
if git push origin HEAD; then
  echo "✅ تم الرفع: https://github.com/Reemiiu/ain-alhamla-db"
else
  echo "⚠️ الرفع يحتاج تسجيل دخول GitHub."
  echo "   افتحي GitHub Desktop ← File ← Add Local Repository ← اختاري المجلد:"
  echo "   $REPO"
  echo "   ثم اضغطي Push origin."
fi
read -n 1 -s -r -p "اضغطي أي زر للإغلاق"
