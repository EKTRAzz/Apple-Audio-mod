# HeSuVi-iOS (Headphone Surround Virtualizer for iOS)

ไลบรารี `.dylib` สำหรับนำฟังก์ชันจำลองมิติเสียงรอบทิศทาง 7.1 ของ **HeSuVi (Equalizer APO)** มาทำงานบน iPhone/iPad โดยเฉพาะ สามารถฉีด (Inject) เข้าแอปเล่นเพลงยอดนิยมอย่าง **Spotify** หรือ **YouTube Music** ผ่านโปรแกรม Sign บนเครื่อง เช่น **KSign**, TrollStore, หรือ Esign

---

## 🌟 ฟีเจอร์หลัก (ตรงตามหน้าจอ HeSuVi บน PC)

1. **Matrix Upmix (Stereo to 7.1)**:
   - แปลงสัญญาณเสียงเพลง 2 แชนแนล (Stereo 2.0) จาก Spotify / YouTube Music ให้กระจายออกเป็น 7.1 แชนแนลเสมือนรอบทิศทาง
   - ตัวเลือก Content Format: **Automatic**, **Stereo**, หรือ **5.1**
2. **HRIR Convolution Engine**:
   - ใช้ **Apple Accelerate Framework (`vDSP`)** ในการทำ Fast FIR Convolution ระดับฮาร์ดแวร์ กินแบตต่ำและไม่มีอาการหน่วงหรือกระตุก (Near Zero Latency)
   - จำลองมิติเสียงตามโปรไฟล์ **AirPods Pro 2 (Spatial / Stereo)**, Apple Spatial, Dolby Atmos
   - มีปุ่มเลือกนำเข้าไฟล์ HRIR `.wav` (14-channel) เพิ่มเติมจากแอป **Files (ไฟล์)** ได้เอง
3. **Volume Adjustment Sliders (0% - 200%)**:
   - ปรับระดับความดังแยกตามตำแหน่งลำโพงเสมือนได้อิสระ: **Master**, **Center**, **Front**, **Side**, **Rear**, และ **LFE (Subwoofer)**
4. **Floating In-App UI**:
   - ปุ่มลอยรูปหูฟัง `🎧` สามารถลากย้ายตำแหน่งได้รอบหน้าจอ
   - แตะเพื่อเปิดแผงควบคุม ปรับค่าเสร็จกด **✕** เพื่อปิดซ่อนหายไปได้อย่างสมบูรณ์
   - หากต้องการซ่อนปุ่มลอยไม่ให้กวนสายตา สามารถแตะหน้าจอด้วย **3 นิ้วพร้อมกัน** เพื่อเปิด/ปิดการแสดงผลปุ่มลอยได้

---

## 🚀 วิธีการ Build อัตโนมัติบน GitHub (ไม่ต้องมี Mac)

โปรเจกต์นี้ตั้งค่า **GitHub Actions CI/CD** ไว้เรียบร้อยแล้ว:

1. นำโฟลเดอร์โปรเจกต์นี้ไป Push ขึ้น GitHub Repository ส่วนตัวของคุณ
2. ไปที่แท็บ **Actions** บน GitHub
3. เลือก Workflow **"Build HeSuVi iOS Dylib"** แล้วกดปุ่ม **"Run workflow"**
4. เมื่อ Build เสร็จสมบูรณ์ (ใช้เวลาประมาณ 1-2 นาที) ให้คลิกเข้าไปที่ผลการรัน แล้วเลื่อนลงมาที่หัวข้อ **Artifacts**
5. ดาวน์โหลดไฟล์ **`HeSuVi.dylib`** มาเก็บไว้ใน iPhone

---

## 📲 วิธีนำไปติดตั้งใน Spotify / YouTube Music ผ่าน KSign

1. เปิดแอป **KSign** บน iPhone ของคุณ
2. เพิ่มไฟล์ `.ipa` ของ **Spotify** หรือ **YouTube Music** เข้ามาใน KSign
3. กดที่ตัวแอป เลือกหัวข้อ **Inject / Signature Settings** (การฉีดไลบรารี / ปรับแต่ง)
4. เลือกเพิ่มไฟล์ **`HeSuVi.dylib`** เข้าไปในรายการ Dynamic Libraries
5. ทำการ Sign ด้วยใบรับรองของคุณ (Certificate) แล้วกด **Install** ติดตั้งลงเครื่อง
6. เปิดแอป Spotify หรือ YouTube Music จะมีไอคอนปุ่มลอย `🎧` ปรากฏขึ้นมา สามารถแตะเพื่อปรับตั้งค่าเสียง HeSuVi ได้ทันที!
