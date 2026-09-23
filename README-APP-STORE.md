# تجهيز التطبيق لمتاجر التطبيقات — خطوات التشغيل والنشر

هذه الحزمة تحتوي على التعديلات التالية جاهزة داخل الكود:
- `public/manifest.json` + أيقونات مبدئية (`icon-192.png`, `icon-512.png`, `apple-touch-icon.png`) — استبدلها بشعارك الحقيقي.
- `public/service-worker.js` مسجّل من `src/main.tsx` (عمل أوفلاين أساسي + تسريع التحميل).
- `index.html` محدّث بعنوان ووصف وميتاداتا صحيحة بدل بيانات bolt.new الافتراضية.
- `capacitor.config.ts` جاهز لتغليف المشروع كتطبيق Android/iOS حقيقي.
- ميزة **حذف الحساب** داخل شاشة الإعدادات (Settings → حذف الحساب نهائيًا)، مع Migration جديدة في
  `supabase/migrations/20260923120000_add_account_deletion_requests.sql` — **لازم تُطبَّق هذه الهجرة
  على مشروع Supabase الخاص بك** (عبر `supabase db push` أو لصقها في SQL Editor) قبل أن تعمل الميزة.
- خانة سعر الدواء: لا وجود لها أصلًا في قاعدة البيانات ولا في الواجهة — لن تظهر لأنها غير موجودة من الأساس.

## تشغيل المشروع للتجربة (على جهازك، مو هنا)
هذه البيئة الحالية بدون اتصال إنترنت، فما أقدر أثبّت الحزم ولا أشغّل خادم تجريبي هنا. شغّله عندك:

```bash
npm install
npm run dev       # للتجربة في المتصفح على http://localhost:5173
npm run build     # لإنتاج نسخة dist/ جاهزة للنشر
```

أو ارفع نفس هذه الملفات مرة ثانية على bolt.new (المصدر الأصلي) للحصول على معاينة حية فورية بدون إعداد شيء.

## تغليف Android (الأسهل: Capacitor)
```bash
npm install @capacitor/core @capacitor/cli @capacitor/android
npx cap add android
npm run build
npx cap sync android
npx cap open android      # يفتح Android Studio لبناء .aab ورفعه لـ Google Play
```

## تغليف iOS
```bash
npm install @capacitor/ios
npx cap add ios
npm run build
npx cap sync ios
npx cap open ios          # يفتح Xcode لبناء وأرشفة ورفعه لـ App Store Connect
```
(يتطلب جهاز Mac + حساب Apple Developer).

## قبل الرفع الفعلي للمتاجر — تأكد من:
1. **مراجعة صلاحيات RLS في Supabase بدقة** — مفتاح anon الموجود في `.env` سيكون مرئيًا لأي شخص يفكك حزمة
   التطبيق، فالحماية الحقيقية الوحيدة هي RLS محكم على كل جدول.
2. نشر **سياسة الخصوصية** و**شروط الاستخدام** كصفحات ثابتة فعلية (النظام موجود مسبقًا في لوحة الأدمن
   ← الصفحات الثابتة) وربط روابطها في نموذج بيانات جوجل بلاي (Data Safety) وآبل (App Privacy).
3. تطبيق هجرة حذف الحساب أعلاه، وربط عملية معالجة الطلبات الفعلية (حذف بيانات المستخدم من `auth.users`
   وجداوله) بواسطة سكربت إداري بصلاحية service role — لا تضع service role key داخل التطبيق نفسه أبدًا.
4. استبدال الأيقونات المؤقتة بشعار حقيقي بجميع المقاسات المطلوبة.
5. اختبار كامل على جهاز حقيقي (خصوصًا الكاميرا ورفع الصور وGPS) بعد التغليف بـ Capacitor.
