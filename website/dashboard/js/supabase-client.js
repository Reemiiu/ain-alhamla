// عميل Supabase المشترك بين كل صفحات لوحة التحكم.
// يُستورد كوحدة ES Module — يعمل عبر أي خادم استضافة ثابت (Netlify, GitHub
// Pages...) أو محلياً عبر خادم بسيط مثل: python3 -m http.server
// (لا يعمل بفتح الملف مباشرة عبر file:// لأن المتصفحات تمنع وحدات ES
// من العمل على بروتوكول file://).

import { createClient } from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm';
import { SUPABASE_URL, SUPABASE_ANON_KEY } from './supabase-config.js';

export const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
