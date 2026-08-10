package com.ibtech.libraryupdater

object UpdaterConfig {
    /**
     * 관리할 앱 전체 목록을 담은 카탈로그 파일. 앱을 새로 추가하거나 버전을 올릴 때는
     * 이 파일만 갱신하면 된다 — 이 관리 앱 자체를 다시 배포할 필요가 없다.
     */
    const val CATALOG_URL = "https://raw.githubusercontent.com/robotibtech-bit/updater/main/apps.json"
}
