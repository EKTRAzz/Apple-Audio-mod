# SpatialAudioMultiHook (iOS arm64 `.dylib`)

ตัวประมวลผลเสียง Spatial Audio แบบเรียลไทม์สำหรับ iOS (`arm64`, iOS 15.0+) ที่จำลองการทำงานของ **HeSuVi (`#2.0.0.1`) บน PC** จากไฟล์ `Apple_Pro2_Stereo.wav` (`48 kHz`, 14 แชนเนล, `8,400 samples` ครบไม่ตัดหาง) พร้อมระบบ **Single-Winner Multi-Pipeline Hook** เพื่อจับท่อเสียงหลักของแอปโดย **ไม่ทับไลน์กัน**

## จุดเด่นหลัก

1. **ตรงกับ HeSuVi บน PC มากที่สุด**
   - ใช้สูตร `matrix.txt` + 14-channel convolution (`hesuvi.txt`) + `mix.txt` ของ HeSuVi PC แท้ๆ ยุบรวมเชิงเส้นเป็น True-Stereo 4 แชนเนล (`LL`, `LR`, `RL`, `RR`) ด้วยความคลาดเคลื่อนระดับ `1e-7`
   - เก็บความยาว Impulse Response ครบทั้ง **`8,400 samples`** (0.175 วินาที ไม่ตัดปลายหางที่ 8192) บน `FFT_N = 16384` แบบ **Zero-Added-Latency Overlap-Save** ผ่าน `Accelerate` (`vDSP_fft_zrip`)
   - แก้การคูณ Bin 0 (DC/Nyquist) ของ `vDSP_fft_zrip` แยกต่างหาก และตั้งค่า Headroom เริ่มต้นที่ **`-2.5 dB`** (รองรับ peak สูงสุด `+2.41 dB` ของ IR โดยไม่ลดความดังจนเบากว่า PC พร้อม Soft Clipper `tanhf` เหนือ `±0.985`)
   - สร้างได้ 2 โหมด:
     - `SpatialDSP_ApplePro2_Matrix.dylib`: โหมด **Matrix Upmix** (ตรงกับ HeSuVi บน PC เมื่อเปิด Stereo Upmix)
     - `SpatialDSP_ApplePro2_Front.dylib`: โหมด **Front 1:1** (ตรงกับ HeSuVi บน PC เมื่อปิด Upmix ใช้เฉพาะ `FL/FR`)

2. **ระบบ Single-Winner Multi-Pipeline Hook (ไม่ทับไลน์กัน)**
   - ติดตั้ง Hook ครอบคลุม 3 ท่อเสียงหลักของแอป iOS:
     1. **AudioUnit / AUGraph / AVAudioEngine** (`RemoteIO` และ `VoiceProcessingIO`) — ผ่าน `fishhook` (`AudioUnitSetProperty`, `AUGraphSetNodeInputCallback`, `AudioUnitInitialize`, `AudioComponentInstanceDispose`)
     2. **AudioQueue (Linear PCM)** — ผ่าน `fishhook` (`AudioQueueNewOutput*`, `AudioQueueEnqueueBuffer*`, `AudioQueueDispose`)
     3. **AVPlayer / AVQueuePlayer** — ผ่าน ObjC Swizzling แนบ `MTAudioProcessingTap` (ข้าม FairPlay DRM และรายการที่มี `audioMix` เดิมอัตโนมัติ)
   - **Exclusive Winner Lock (`PipelineCoordinator`):** ท่อไหนที่ได้รับเสียงจริงก่อนจะเป็น **ท่อหลักเพียงท่อเดียว** ท่ออื่นทั้งหมดจะปล่อยผ่าน (Bypass) อัตโนมัติทันที และหากท่อหลักปิดสตรีมหรือเงียบเกิน `1.5 วินาที` ระบบจะปลดล็อกให้ท่อใหม่รับช่วงต่อได้โดยไม่ชนกัน

3. **Auto-Bypass อุปกรณ์แบบ Lock-Free**
   - ฟัง `AVAudioSessionRouteChangeNotification` แล้วเก็บสถานะใน `std::atomic<bool>` (ไม่เรียก ObjC บนเธรดเสียงจริง)
   - ทำงานเฉพาะเมื่อต่อ **หูฟังมีสาย, Bluetooth A2DP/LE หรือ USB DAC** และข้ามอัตโนมัติเมื่อออก **ลำโพงเครื่อง, Receiver, CarPlay, AirPlay, HDMI, Bluetooth HFP หรือโหมด Voice/Video Call**

## วิธี Build เป็นไฟล์ `.dylib`

### วิธีที่ 1: ใช้ GitHub Actions (แนะนำ — ไม่ต้องมีเครื่อง Mac)
1. แตกไฟล์ `.zip` นี้แล้วอัปโหลดขึ้น GitHub Repository ของคุณ
2. เปิดแท็บ **Actions** -> เลือก workflow **Build iOS Spatial Audio dylib** -> กด **Run workflow** (ปรับค่า `headroom_db` ได้ เช่น `-2.5f`, `-4.0f`, หรือ `0.0f`)
3. ดาวน์โหลดไฟล์ `SpatialDSP_ApplePro2_Matrix.dylib` และ `SpatialDSP_ApplePro2_Front.dylib` จากส่วน **Artifacts**

### วิธีที่ 2: คอมไพล์บนเครื่อง Mac
```bash
mkdir -p third_party
git clone --depth 1 https://github.com/facebook/fishhook.git third_party/fishhook
make all
```

### วิธีเปลี่ยนไฟล์ HRIR `.wav` ในอนาคต
```bash
python3 tools/wav_to_ir.py path/to/your_14ch_hesuvi.wav src/ir_data.h
make all
```

## ข้อจำกัดของ iOS Sandbox
- สตรีมเสียงที่เข้ารหัส **FairPlay DRM** (เช่น Apple Music DRM, Netflix DRM), เสียงใน **WKWebView** (รันแยกโปรเซส), และ **Compressed AudioQueue** ที่ส่งไปถอดรหัสใน `mediaserverd` จะถูกปล่อยผ่านตามปกติเพื่อไม่ให้เสียงเงียบหรือแอปแครช
