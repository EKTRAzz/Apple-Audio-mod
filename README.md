# SpatialAudioMultiHook (iOS arm64 `.dylib`)

ตัวประมวลผลเสียง Spatial Audio แบบเรียลไทม์สำหรับ iOS (`arm64`, iOS 15.0+) ที่จำลองการทำงานของ **HeSuVi (`#2.0.0.1`) บน PC** จากไฟล์ `Apple_Pro2_Stereo.wav` (`48 kHz`, 14 แชนเนล, `8,400 samples` ครบไม่ตัดหาง) พร้อมระบบ **Single-Winner Multi-Pipeline Hook** เพื่อจับท่อเสียงหลักของแอป (รวมถึง Spotify และ YouTube Music) โดย **ไม่ทับไลน์กัน**

## จุดเด่นหลัก

1. **ตรงกับ HeSuVi บน PC มากที่สุด**
   - ใช้สูตร `matrix.txt` + 14-channel convolution (`hesuvi.txt`) + `mix.txt` ของ HeSuVi PC แท้ๆ ยุบรวมเชิงเส้นเป็น True-Stereo 4 แชนเนล (`LL`, `LR`, `RL`, `RR`) ด้วยความคลาดเคลื่อนระดับ `1e-7`
   - เก็บความยาว Impulse Response ครบทั้ง **`8,400 samples`** (0.175 วินาที ไม่ตัดปลายหางที่ 8192) บน `FFT_N = 16384` แบบ **Zero-Added-Latency Overlap-Save** ผ่าน `Accelerate` (`vDSP_fft_zrip`)
   - แก้การคูณ Bin 0 (DC/Nyquist) ของ `vDSP_fft_zrip` แยกต่างหาก และตั้งค่า Headroom เริ่มต้นที่ **`-2.5 dB`** (รองรับ peak สูงสุด `+2.41 dB` ของ IR โดยไม่ลดความดังจนเบากว่า PC พร้อม Soft Clipper `tanhf` เหนือ `±0.985`)
   - รวมทั้ง 2 โหมดไว้ในไฟล์ `.dylib` เดียว (`SpatialDSP_ApplePro2.dylib`) และสลับโหมดแบบเรียลไทม์พร้อม Crossfade ~10 ms ไม่เกิดเสียงคลิก:
     - **Matrix (Upmix)** (ค่าเริ่มต้น): โหมดจำลองลำโพงรอบทิศทางตรงกับ HeSuVi บน PC เมื่อเปิด Stereo Upmix
     - **Front (1:1)**: โหมด `FL/FR` ตรงกับ HeSuVi บน PC เมื่อปิด Upmix

2. **แผงควบคุมในแอป (In-App Floating Control Panel UI)**
   - **ปุ่มลอยขอบจอ (Floating Button)**: ลากย้ายตำแหน่งและดูดติดขอบซ้าย/ขวาอัตโนมัติ (จางลงอัตโนมัติเมื่อไม่ได้ใช้งาน)
     - **แตะ 1 ครั้ง**: เปิด/ปิดหน้าต่างควบคุม Spatial Audio
     - **กดค้าง (Long-Press)**: เปิด/ปิด Spatial Audio ทันทีพร้อม Haptic Feedback สำหรับเทสเทียบเสียง (A/B)
     - **แตะ 3 นิ้วพร้อมกันตรงไหนก็ได้บนหน้าจอ** (หรือกดปุ่มซ่อนในหน้าต่าง): ซ่อน/แสดงปุ่มลอย
   - **หน้าต่างควบคุมและสถานะสด (Live Status)**:
     - สวิตช์ **Enable Spatial Audio** (เปิด/ปิดการประมวลผล โดยยังคงระบบ Auto-Bypass เมื่อออกลำโพงเครื่อง/โทรอัตโนมัติ)
     - **HRIR Profile & Mode**: สลับระหว่าง `Apple Pro 2` กับไฟล์ `.wav` ที่นำเข้าจากแอป Files เองได้ (รองรับ 14-ch HeSuVi, 4-ch True-Stereo และ 2-ch Stereo) พร้อมเลือก `Matrix (Upmix)` / `Front (1:1)` แบบเรียลไทม์
     - **DSP Tuning**: ปรับ `Spatial Mix` (`0%–100%`), `Output Gain` (`-6.0` ถึง `+4.0 dB`), `Spatial Width` (`50%–180%`) พร้อมปุ่ม `Reset`
     - **Audio Hooks**: เลือกได้ 3 โหมด: **`Auto`** (Single-Winner อัตโนมัติ), **`Force Bridge`** (ดึงเสียง YouTube Music `SampleBufferRenderer` มารันผ่าน `RemoteIO AudioUnit` ลดดีเลย์คิวจาก 2–5 วินาทีเหลือ ~5–20 ms พร้อมสลับกลับอัตโนมัติเมื่อออกลำโพง/AirPlay/สายโทร) หรือ **`Custom`** (เปิด/ปิดท่อเสียงรายตัว)
     - แสดงสถานะสด: **State** (Active หรือเหตุผลที่ Bypass), **Output Route**, **Pipeline** ที่กำลังใช้งาน และ **Sample Rate**
     - บันทึกค่าทั้งหมดแยกตามแอปอัตโนมัติใน `NSUserDefaults` (และเก็บไฟล์ `.wav` ที่นำเข้าใน `Application Support`)

3. **ระบบ Single-Winner Multi-Pipeline Hook 4 ท่อเสียง (รองรับ Spotify & YouTube Music)**
   - ติดตั้ง Hook ครอบคลุม 4 ท่อเสียงหลักของแอป iOS:
     1. **AudioUnit / AUGraph / AVAudioEngine** (`RemoteIO` และ `VoiceProcessingIO`) — ผ่าน `fishhook` (`AudioUnitSetProperty`, `AUGraphSetNodeInputCallback`, `AudioUnitInitialize`, `AudioOutputUnitStart`, `AudioComponentInstanceDispose`) และ ObjC Swizzling บน `AVAudioEngine` (`prepare`, `startAndReturnError:`)
     2. **AudioQueue (Linear PCM)** — ผ่าน `fishhook` (`AudioQueueNewOutput*`, `AudioQueueEnqueueBuffer*`, `AudioQueueDispose`) รองรับ Float32, Int16 และ Int32
     3. **AVPlayer / AVQueuePlayer** — ผ่าน ObjC Swizzling แนบ `MTAudioProcessingTap` พร้อม KVO ดักจับแทร็กเสียงของสตรีม HLS และผสานเข้ากับ `audioMix` เดิมของแอป (ไม่โดนระบบ Loudness Normalization ทับ)
     4. **AVSampleBufferAudioRenderer** — ผ่าน ObjC Swizzling (`enqueueSampleBuffer:`, `flush`, `flushFromSourceTime:completionHandler:`) รองรับทั้ง Linear PCM และถอดรหัสสตรีมบีบอัด (AAC / HE-AAC / Opus / MP3) ในโปรเซสผ่าน `AudioConverter` เพื่อประมวลผล Spatial Audio (แก้ปัญหา YouTube Music / `HAMPlayer`)
   - **Exclusive Winner Lock (`PipelineCoordinator`):** ท่อไหนที่ได้รับเสียงจริงก่อนจะเป็น **ท่อหลักเพียงท่อเดียว** ท่ออื่นทั้งหมดจะปล่อยผ่าน (Bypass) อัตโนมัติทันที และหากท่อหลักปิดสตรีมหรือเงียบเกิน `1.5 วินาที` ระบบจะปลดล็อกให้ท่อใหม่รับช่วงต่อได้โดยไม่ชนกัน

4. **Auto-Bypass อุปกรณ์แบบ Lock-Free**
   - ฟัง `AVAudioSessionRouteChangeNotification`, `AVAudioSessionInterruptionNotification`, `AVAudioSessionMediaServicesWereResetNotification` และ `UIApplicationDidBecomeActiveNotification` แล้วเก็บสถานะใน `std::atomic<bool>` (ไม่เรียก ObjC บนเธรดเสียงจริง)
   - ทำงานเฉพาะเมื่อต่อ **หูฟังมีสาย, Bluetooth A2DP/LE หรือ USB DAC** และข้ามอัตโนมัติเมื่อออก **ลำโพงเครื่อง, Receiver, CarPlay, AirPlay, HDMI, Bluetooth HFP หรือโหมด Voice/Video Call**

## วิธี Build เป็นไฟล์ `.dylib`

### วิธีที่ 1: ใช้ GitHub Actions (แนะนำ — ไม่ต้องมีเครื่อง Mac)
1. แตกไฟล์ `.zip` นี้แล้วอัปโหลดขึ้น GitHub Repository ของคุณ
2. เปิดแท็บ **Actions** -> เลือก workflow **Build iOS Spatial Audio dylib** -> กด **Run workflow** (ปรับค่า `headroom_db` ได้ เช่น `-2.5f`, `-4.0f`, หรือ `0.0f`)
3. ดาวน์โหลดไฟล์ `SpatialDSP_ApplePro2.dylib` จากส่วน **Artifacts**

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

## การใช้งานกับ YouTube Music iOS

1. Build โปรเจกต์ผ่าน GitHub Actions เพื่อรับไฟล์ `SpatialDSP_ApplePro2.dylib`
2. นำไป Inject เข้าไฟล์ `.ipa` ของ YouTube Music ด้วยเครื่องมือ Sideload/Sign ที่รองรับ (เช่น Sideloadly, ESign, Feather หรือ LiveContainer) หรือติดตั้งผ่านเครื่อง Jailbreak
3. ต่อ **หูฟังมีสาย, Bluetooth (A2DP/LE) หรือ USB DAC** แล้วเปิดเพลงทดสอบ — แตะปุ่มลอยหูฟังบนหน้าจอเพื่อเปิดแผงควบคุม สลับโหมด `Matrix` / `Front` หรือดูสถานะท่อเสียงสด (หากฟังผ่านลำโพงเครื่อง ระบบจะ Bypass อัตโนมัติ)

## ข้อจำกัดของ iOS Sandbox
- สตรีมเสียงที่เข้ารหัส **FairPlay DRM** (เช่น Apple Music DRM, Netflix DRM), เสียงใน **WKWebView** (รันแยกโปรเซส), และ **Compressed AudioQueue** ที่ส่งไปถอดรหัสใน `mediaserverd` จะถูกปล่อยผ่านตามปกติเพื่อไม่ให้เสียงเงียบหรือแอปแครช
