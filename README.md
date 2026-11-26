# API Peminjaman Alat (Serverless, Track C)

API REST sederhana untuk mencatat peminjaman alat, dibangun sebagai dua microservice serverless di AWS.
Proyek individu mata kuliah Komputasi Awan (Track C: Serverless).

| | |
|---|---|
| Nama | Bintang Khalifa Hadianto |
| NIM | 24/534951/TK/59312 |
| NIU | 534951 |
| Lingkungan | AWS Academy Cloud Foundations Sandbox, region `us-east-1` |

## 1. Fungsi aplikasi

Setiap peminjaman alat (proyektor, kamera, laptop, dan sebagainya) dicatat sebagai sebuah **loan**.
Satu loan berisi nama alat, nama peminjam, tanggal pinjam, tanggal kembali (opsional), dan status
(`borrowed` atau `returned`). API menyediakan empat operasi CRUD lewat HTTP dan menyimpan data di
penyimpanan AWS, sehingga data tetap ada setelah fungsi di-restart.

## 2. Arsitektur Diagram

![Arsitektur](docs/architecture.png)

Sumber diagram ada di `docs/architecture.drawio` (buka dengan https://app.diagrams.net).

API dipecah menjadi **dua microservice** yang di-deploy sebagai dua fungsi Lambda terpisah:

| Microservice | Fungsi Lambda | Endpoint | Alasan dipisah |
|---|---|---|---|
| Read | `loan-read` | `GET /health`, `GET /loans`, `GET /loans/{id}` | Hanya membaca, paling banyak dipakai |
| Write | `loan-write` | `POST /loans`, `PUT /loans/{id}`, `DELETE /loans/{id}` | Mengubah data, wajib memakai token API |

Kalau `loan-write` bermasalah, `loan-read` tetap berjalan. Ini dibuktikan di skenario kegagalan
(bagian 9).

### Layanan AWS yang dipakai

Rancangan awal mengikuti slide: API Gateway + Lambda + DynamoDB. Saat deploy di sandbox, pembuatan
tabel DynamoDB (`dynamodb:CreateTable`) dan pembuatan API di API Gateway (`apigateway:POST`) ditolak
dengan `AccessDeniedException` oleh kebijakan sandbox, jadi dipakai alternatif yang setara:

| Peran | Rencana (slide) | **As-built (yang ter-deploy)** |
|---|---|---|
| Pintu masuk API | API Gateway (HTTP API) | **Application Load Balancer** dengan target Lambda |
| Komputasi | AWS Lambda (Python) x 2 | **AWS Lambda (Python 3.12) x 2** |
| Penyimpanan | DynamoDB (tabel `loans`) | **Amazon S3** (satu objek JSON per loan) |
| Log | CloudWatch Logs | **CloudWatch Logs** |
| IAM | `LabRole` | **`LabRole`** (execution role) |

Bukti penolakan DynamoDB dan API Gateway ada di `evidence/w12-07-access-denied.png`.

ALB meneruskan request berdasarkan method dan path:

| Prioritas | Kondisi | Tujuan |
|---|---|---|
| 10 | `GET` pada `/health`, `/loans`, `/loans/*` | `loan-read-tg` (Lambda `loan-read`) |
| 20 | `POST`, `PUT`, `DELETE` pada `/loans`, `/loans/*` | `loan-write-tg` (Lambda `loan-write`) |
| default | selain di atas | respons tetap 404 `{"error":"route not found"}` |

Kondisi deploy saat pengujian:

- Region: `us-east-1`
- Fungsi Lambda: `loan-read` dan `loan-write` (Python 3.12, 128 MB, timeout 10 detik)
- Bucket S3: `equipment-loans-<account-id>`, objek di `loans/{id}.json`
- Base URL: `http://equipment-loans-alb-58598994.us-east-1.elb.amazonaws.com`
  (sudah tidak aktif karena resource dihapus setelah pengujian)

## 3. API

Base URL mengikuti hasil deploy, bentuknya `http://<nama-dns-alb>`. Semua body berformat JSON.

| Method | Path | Service | Autentikasi | Sukses | Keterangan |
|---|---|---|---|---|---|
| GET | `/health` | loan-read | tidak ada | 200 | Cek layanan |
| GET | `/loans` | loan-read | tidak ada | 200 | Daftar semua loan |
| GET | `/loans/{id}` | loan-read | tidak ada | 200 | Satu loan (404 kalau tidak ada) |
| POST | `/loans` | loan-write | `x-api-key` | 201 | Membuat loan |
| PUT | `/loans/{id}` | loan-write | `x-api-key` | 200 | Mengubah field loan |
| DELETE | `/loans/{id}` | loan-write | `x-api-key` | 200 | Menghapus loan |

### Entitas data: `loan`

| Field | Tipe | Catatan |
|---|---|---|
| `id` | string | UUID, dibuat oleh service |
| `equipment_name` | string | wajib, maksimal 100 karakter |
| `borrower_name` | string | wajib, maksimal 100 karakter |
| `loan_date` | string | wajib, format `YYYY-MM-DD` |
| `return_date` | string atau null | `YYYY-MM-DD`; terisi otomatis saat status menjadi `returned` |
| `status` | string | `borrowed` (default) atau `returned` |
| `created_at`, `updated_at` | string | timestamp UTC, diisi oleh service |

### Contoh pemakaian

```bash
# buat loan
curl -X POST "$BASE_URL/loans" -H "Content-Type: application/json" -H "x-api-key: $API_TOKEN" \
  -d '{"equipment_name":"Proyektor Epson","borrower_name":"Bibin","loan_date":"2026-11-26"}'

# daftar dan baca satu loan
curl "$BASE_URL/loans"
curl "$BASE_URL/loans/<id>"

# ubah (tandai sudah dikembalikan)
curl -X PUT "$BASE_URL/loans/<id>" -H "Content-Type: application/json" -H "x-api-key: $API_TOKEN" \
  -d '{"status":"returned"}'

# hapus
curl -X DELETE "$BASE_URL/loans/<id>" -H "x-api-key: $API_TOKEN"
```

Respons error berupa JSON `{"error": "..."}` dengan status 400 (input salah), 401 (token kosong atau
salah), 404 (tidak ditemukan), 405 (method tidak sesuai service), atau 500 (masalah di server).

## 4. Struktur repositori

```
src/
  shared/        parsing HTTP dan respons, aturan validasi, penyimpanan (DynamoDB atau S3)
  loan_read/     handler.py  - microservice baca
  loan_write/    handler.py  - microservice tulis
tests/
  test_api.py          unit test (moto menirukan DynamoDB dan S3)
  smoke_test.sh        uji end-to-end terhadap API yang sudah ter-deploy
  persistence_test.sh  data harus tetap ada setelah restart
infra/
  deploy.sh            membuat semua resource (AWS CLI)
  teardown.sh          menghapus semua resource
  build.py             membuat dua zip Lambda
  failure_demo.sh      merusak / memulihkan loan-write
  restart_functions.sh memaksa cold start kedua fungsi
  lambda_env.py        pembantu untuk mengubah environment variable Lambda
docs/                  diagram, rencana deploy, checklist bukti, naskah demo
evidence/              screenshot dan keluaran pengujian
```

## 5. Menjalankan test lokal

```bash
pip install -r requirements-dev.txt
pytest -v
```

## 6. Deploy ke AWS Academy Sandbox

Jalankan di AWS CloudShell:

```bash
git clone <url-repo-ini> && cd <folder-repo>

./infra/deploy.sh                                     # API Gateway + DynamoDB (sesuai slide)
# kalau DynamoDB diblokir:    STORAGE_BACKEND=s3 ./infra/deploy.sh
# kalau API Gateway diblokir: API_FRONT=alb STORAGE_BACKEND=s3 ./infra/deploy.sh
```

Yang dipakai pada deploy ini adalah perintah terakhir (`API_FRONT=alb STORAGE_BACKEND=s3`).
Script memakai `LabRole` yang sudah ada karena role IAM baru tidak bisa dibuat di sandbox.
Langkah lengkap ada di [`docs/deployment-plan.md`](docs/deployment-plan.md).

## 7. Menguji deployment

```bash
./tests/smoke_test.sh | tee evidence/smoke-test-output.txt
./tests/persistence_test.sh write
./infra/restart_functions.sh
./tests/persistence_test.sh check | tee -a evidence/persistence-output.txt
```

Bukti pengujian yang tersimpan di folder `evidence/`:

| Pengujian | Berkas |
|---|---|
| CRUD dan validasi (9 pemeriksaan lolos) | `smoke-test-output.txt`, `w14-01-crud-curl.png` |
| Keamanan: tulis tanpa token ditolak 401 | `w14-02-security-401.png` |
| Persistensi setelah restart fungsi | `persistence-output.txt`, `w14-03-persistence.png` |
| Token tidak tampil di environment variable (hanya nama) | `w14-03-env-vars-masked.png` |
| Pemindaian secret di repo | `w14-07-secret-scan.png` |
| Kegagalan: tulis 500, baca tetap 200 | `w14-04-failure-500.png` |
| Pemulihan setelah `restore` | `recovery-output.txt`, `w14-05-recovery.png` |
| Log permintaan di CloudWatch | `w14-06-cloudwatch-logs.png` |
| Pembersihan resource | `w14-07-cleanup-terminal.png`, `w14-07-cleanup-lambda.png`, `w14-07-cleanup-alb.png`, `w14-07-cleanup-targetgroups.png`, `w14-07-cleanup-s3.png`, `w14-07-cleanup-cloudwatch.png` |
| Infrastruktur Week 12 (Lambda, S3, ALB, IAM, health) | `w12-01` sampai `w12-08` |

## 8. Keamanan dan observability

- **Tidak ada secret di Git.** Token API dibuat oleh `deploy.sh`, disimpan di `~/.loans_token` di luar
  repositori, dan hanya dipasang sebagai environment variable pada `loan-write`. `.gitignore`
  juga memblokir `.env`, `*.pem`, dan `*.ppk`.
- **Endpoint tulis wajib `x-api-key`.** Pemeriksaan memakai perbandingan constant-time dan gagal
  tertutup (HTTP 500) kalau token belum dikonfigurasi. Endpoint baca bersifat publik karena data
  contoh tidak sensitif.
- **Validasi input:** field wajib, panjang teks, tanggal `YYYY-MM-DD`, status yang diizinkan;
  `id` tidak dapat diubah.
- **IAM:** kedua fungsi memakai `LabRole`. Ini lebih longgar daripada least privilege, tetapi sandbox
  tidak mengizinkan pembuatan role. Di akun biasa, setiap fungsi sebaiknya punya role sendiri: akses
  baca saja untuk `loan-read` dan akses tulis untuk `loan-write`.
- **Penyimpanan:** bucket S3 memakai Block Public Access (aktif) dan hanya bisa diakses lewat IAM.
- **Jaringan:** security group ALB hanya mengizinkan HTTP (port 80) masuk.
- **Log dan monitoring:** tiap request menulis satu baris log JSON (service, method, path, status)
  ke CloudWatch Logs (`/aws/lambda/loan-read`, `/aws/lambda/loan-write`). Token tidak pernah dicatat.

## 9. Skenario kegagalan dan pemulihan

```bash
./infra/failure_demo.sh break      # loan-write diarahkan ke penyimpanan yang tidak ada
./tests/smoke_test.sh              # tulis menghasilkan HTTP 500, baca tetap 200
./infra/failure_demo.sh restore    # pengaturan penyimpanan dikembalikan
./tests/smoke_test.sh              # semua pemeriksaan lolos lagi
```

Skenario ini memperlihatkan manfaat memecah API menjadi dua microservice: kegagalan hanya
berdampak pada sisi tulis, sedangkan sisi baca tetap melayani request.

## 10. Pembersihan resource

```bash
./infra/teardown.sh
```

Script menghapus ALB, target group, security group, fungsi Lambda, log group, dan bucket S3.
Sandbox juga menghapus semua resource saat sesi berakhir.

## 11. Keterbatasan dan trade-off

- API Gateway dan DynamoDB tidak dapat dipakai di sandbox, sehingga diganti ALB dan S3. ALB
  menambah biaya per jam dibanding API Gateway, jadi resource perlu dihapus setelah demo.
- Function URL Lambda dan API key bawaan API Gateway tidak dipakai; token bersama di header adalah
  proteksi paling sederhana yang cocok dengan sandbox.
- Daftar loan dibaca dengan memindai seluruh prefix `loans/` di S3. Cukup untuk demo, kurang cocok untuk
  data besar (di DynamoDB bisa memakai indeks atau query).
- Satu `LabRole` dipakai bersama, bukan satu role per fungsi (batasan sandbox).
- Sandbox dibersihkan di akhir sesi, jadi deployment dibangun ulang dengan satu perintah.
