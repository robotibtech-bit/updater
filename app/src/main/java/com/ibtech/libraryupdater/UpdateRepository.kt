package com.ibtech.libraryupdater

import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.net.MalformedURLException
import java.net.SocketTimeoutException
import java.net.URL
import javax.net.ssl.HttpsURLConnection

class UpdateRepository(private val context: Context) {
    private val packageManager = context.packageManager

    /** 이 태블릿에 [packageName]이 설치돼 있으면 버전 정보를, 아니면 null을 돌려준다. */
    fun getInstalledInfo(packageName: String): InstalledAppInfo? = try {
        val info = packageManager.getPackageInfo(packageName, 0)
        val versionCode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            info.longVersionCode
        } else {
            @Suppress("DEPRECATION") info.versionCode.toLong()
        }
        InstalledAppInfo(versionCode, info.versionName.orEmpty().ifBlank { "알 수 없음" })
    } catch (_: PackageManager.NameNotFoundException) {
        null
    }

    /** 카탈로그(apps.json)를 내려받아 관리 대상 앱 목록을 돌려준다. */
    fun fetchCatalog(): List<AppCatalogEntry> {
        val url = requireHttps(UpdaterConfig.CATALOG_URL, "카탈로그 URL")
        val connection = openConnection(url)
        return try {
            val body = connection.inputStream.bufferedReader(Charsets.UTF_8).use { it.readText() }
            parseCatalog(body)
        } finally {
            connection.disconnect()
        }
    }

    fun downloadApk(entry: AppCatalogEntry, onProgress: (Int) -> Unit): File {
        val connection = openConnection(requireHttps(entry.apkUrl, "APK URL"))
        val directory = File(context.cacheDir, "updates").apply { mkdirs() }
        // 여러 앱을 동시에 관리하므로 파일명이 앱마다 겹치지 않게 appId를 넣는다.
        val partial = File(directory, "${entry.appId}.apk.part")
        val output = File(directory, "${entry.appId}.apk")
        try {
            val total = connection.contentLengthLong
            connection.inputStream.use { input ->
                partial.outputStream().buffered().use { sink ->
                    val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                    var downloaded = 0L
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        sink.write(buffer, 0, count)
                        downloaded += count
                        if (total > 0) onProgress(((downloaded * 100) / total).toInt().coerceIn(0, 100))
                    }
                }
            }
            if (partial.length() == 0L) throw IOException("다운로드된 APK 파일이 비어 있습니다.")
            if (output.exists() && !output.delete()) throw IOException("이전 APK 파일을 지울 수 없습니다.")
            if (!partial.renameTo(output)) throw IOException("다운로드 파일을 확정할 수 없습니다.")
            verifyApk(output, entry.packageName)
            onProgress(100)
            return output
        } catch (error: Exception) {
            partial.delete()
            output.delete()
            throw error
        } finally {
            connection.disconnect()
        }
    }

    private fun verifyApk(file: File, expectedPackage: String) {
        val archive = packageManager.getPackageArchiveInfo(file.absolutePath, 0)
            ?: throw InvalidApkException("다운로드 파일을 유효한 APK로 확인할 수 없습니다.")
        if (archive.packageName != expectedPackage) {
            throw InvalidApkException("APK packageName이 카탈로그와 일치하지 않습니다.")
        }
    }

    private fun parseCatalog(body: String): List<AppCatalogEntry> = try {
        val root = JSONObject(body)
        val apps = root.getJSONArray("apps")
        (0 until apps.length()).map { index -> parseEntry(apps.getJSONObject(index)) }
    } catch (error: JSONException) {
        throw InvalidCatalogException("apps.json 형식을 해석할 수 없습니다.", error)
    }

    private fun parseEntry(json: JSONObject): AppCatalogEntry {
        val entry = AppCatalogEntry(
            appId = json.getString("appId"),
            displayName = json.getString("displayName"),
            packageName = json.getString("packageName"),
            versionCode = json.getLong("versionCode"),
            versionName = json.getString("versionName"),
            apkUrl = json.getString("apkUrl"),
            releaseNote = json.optString("releaseNote", "업데이트 내용이 없습니다."),
        )
        if (entry.versionCode < 1 || entry.versionName.isBlank() || entry.packageName.isBlank()) {
            throw InvalidCatalogException("'${entry.appId}' 항목의 값이 올바르지 않습니다.")
        }
        return entry
    }

    private fun openConnection(url: URL): HttpsURLConnection {
        val connection = url.openConnection() as HttpsURLConnection
        connection.connectTimeout = 15_000
        connection.readTimeout = 30_000
        connection.instanceFollowRedirects = true
        connection.setRequestProperty("Accept", "application/json, application/vnd.android.package-archive")
        connection.setRequestProperty("User-Agent", "IBTechAppManager/1.0")
        connection.connect()
        if (connection.responseCode !in 200..299) {
            val code = connection.responseCode
            connection.disconnect()
            throw HttpStatusException(code)
        }
        return connection
    }

    private fun requireHttps(value: String, label: String): URL {
        val url = try { URL(value) } catch (error: MalformedURLException) {
            throw InvalidCatalogException("$label 형식이 올바르지 않습니다.", error)
        }
        if (url.protocol != "https") throw InvalidCatalogException("${label}은 HTTPS여야 합니다.")
        return url
    }
}

class HttpStatusException(val statusCode: Int) : IOException("HTTP $statusCode")
class InvalidCatalogException(message: String, cause: Throwable? = null) : Exception(message, cause)
class InvalidApkException(message: String) : Exception(message)

fun Throwable.toUserMessage(operation: String): String = when (this) {
    is SocketTimeoutException -> "$operation 시간이 초과되었습니다. 인터넷 연결을 확인하고 다시 시도해 주세요."
    is java.net.UnknownHostException, is java.net.ConnectException ->
        "인터넷에 연결할 수 없습니다. 네트워크를 확인하고 다시 시도해 주세요."
    is HttpStatusException -> "GitHub에서 파일을 가져오지 못했습니다. (HTTP $statusCode)"
    is InvalidCatalogException, is InvalidApkException -> message ?: "${operation}에 실패했습니다."
    is IOException -> "$operation 중 오류가 발생했습니다. 다시 시도해 주세요."
    else -> "${operation} 중 알 수 없는 오류가 발생했습니다."
}
