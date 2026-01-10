#!/usr/bin/env python3
import argparse
import curses
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import textwrap
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

REPO_OWNER = "RoversX"
REPO_NAME = "LaunchNext"
DEFAULT_INSTALL = "/Applications/LaunchNext.app"
DEFAULT_PATTERN = r"LaunchNext.*\.zip"
CONFIG_NAME = "config.json"
LOG_NAME = "updater.log"
DOWNLOADS_SUBDIR = "downloads"

STRINGS = {
    "en": {
        "language_prompt": "Select language:\n  1) English\n  2) 简体中文\n  3) 日本語\n  4) 한국어\n  5) Français\n  6) Español\n  7) Deutsch\n  8) Русский\n  9) हिन्दी\n 10) Tiếng Việt\nEnter choice [1]: ",
        "language_saved": "Language preference saved.",
        "fetching": "Fetching release metadata from {url}",
        "latest_tag": "Latest release tag: {tag}",
        "asset_selected": "Selected asset: {name} ({size} bytes)",
        "no_asset": "No release asset matches pattern {pattern}",
        "no_asset_auto": "No asset matches pattern {pattern}. Available assets: {assets}",
        "no_assets_available": "Release contains no downloadable assets.",
        "asset_fallback": "No asset matches pattern {pattern}. Select from available assets:",
        "prompt_asset_choice": "Select asset [1-{count}] (default 1): ",
        "downloading": "Downloading asset...",
        "download_complete": "Downloaded to {path} ({size} bytes)",
        "extracting": "Extracting archive...",
        "found_bundle": "Found bundle: {path}",
        "remove_quarantine_ok": "Removed quarantine attributes",
        "remove_quarantine_warn": "Warning: failed to remove quarantine attributes",
        "download_only_path": "Download-only: bundle available at {path}",
        "install_prepare": "Preparing to install into {path}",
        "requires_admin": "Administrator privileges required. Please enter your password if prompted.",
        "install_complete": "Installation complete",
        "relaunch_warn": "Warning: failed to relaunch LaunchNext automatically",
        "release_notes": "Release notes: {url}",
        "update_complete": "Update complete: {tag}",
        "update_elapsed": "Update finished in {seconds}s",
        "cancelled": "Update cancelled by user.",
        "prompt_continue": "Proceed with installation to {path}? [Y/n]: ",
        "prompt_download_only": "Download without installing? [y/N]: ",
        "invalid_choice": "Invalid choice.",
        "download_only_selected": "Download-only mode selected.",
        "download_and_install": "Download and install selected.",
        "prompt_language_change": "Change language (current: {lang})? [y/N]: ",
        "press_enter": "Press Enter to close this window...",
    },
    "zh": {
        "language_prompt": "选择语言：\n  1) English\n  2) 简体中文\n  3) 日本語\n  4) 한국어\n  5) Français\n  6) Español\n  7) Deutsch\n  8) Русский\n  9) हिन्दी\n 10) Tiếng Việt\n请输入序号 [1]：",
        "language_saved": "语言偏好已保存。",
        "fetching": "正在获取发布信息：{url}",
        "latest_tag": "最新版本标签：{tag}",
        "asset_selected": "已选择资源：{name}（{size} 字节）",
        "no_asset": "没有资源匹配正则：{pattern}",
        "no_asset_auto": "没有资源匹配正则 {pattern}。可用资源：{assets}",
        "no_assets_available": "该发布没有任何可下载资源。",
        "asset_fallback": "没有资源匹配正则 {pattern}，请选择下列资源：",
        "prompt_asset_choice": "请选择资源 [1-{count}]（默认 1）：",
        "downloading": "正在下载资源…",
        "download_complete": "已下载到 {path}（{size} 字节）",
        "extracting": "正在解压…",
        "found_bundle": "找到应用：{path}",
        "remove_quarantine_ok": "已移除隔离属性",
        "remove_quarantine_warn": "警告：移除隔离属性失败",
        "download_only_path": "仅下载模式：应用位于 {path}",
        "install_prepare": "准备安装到 {path}",
        "requires_admin": "需要管理员权限，请根据提示输入密码。",
        "install_complete": "安装完成",
        "relaunch_warn": "警告：自动重新打开 LaunchNext 失败",
        "release_notes": "更新说明：{url}",
        "update_complete": "更新完成：{tag}",
        "update_elapsed": "本次更新耗时 {seconds} 秒",
        "cancelled": "用户已取消更新。",
        "prompt_continue": "即将安装至 {path}，是否继续？[Y/n]：",
        "prompt_download_only": "是否仅下载而不安装？[y/N]：",
        "invalid_choice": "输入无效。",
        "download_only_selected": "已选择仅下载模式。",
        "download_and_install": "已选择下载并安装。",
        "prompt_language_change": "更改语言（当前：{lang}）？[y/N]：",
        "press_enter": "按回车键关闭此窗口…",
    },
    "ja": {
        "language_prompt": "言語を選択してください:\n  1) English\n  2) 简体中文\n  3) 日本語\n  4) 한국어\n  5) Français\n  6) Español\n  7) Deutsch\n  8) Русский\n  9) हिन्दी\n 10) Tiếng Việt\n選択 [1]: ",
        "language_saved": "言語設定を保存しました。",
        "fetching": "GitHub からリリース情報を取得中: {url}",
        "latest_tag": "最新リリースタグ: {tag}",
        "asset_selected": "選択したアセット: {name} ({size} bytes)",
        "no_asset": "正規表現 {pattern} に一致するアセットがありません。",
        "no_asset_auto": "正規表現 {pattern} に一致するアセットがありません。利用可能: {assets}",
        "no_assets_available": "このリリースにはダウンロード可能なアセットがありません。",
        "asset_fallback": "正規表現 {pattern} に一致するアセットがありません。次から選択してください:",
        "prompt_asset_choice": "アセットを選択 [1-{count}] (既定 1): ",
        "downloading": "アセットをダウンロード中…",
        "download_complete": "{path} にダウンロードしました ({size} bytes)",
        "extracting": "アーカイブを展開しています…",
        "found_bundle": "アプリケーションを検出: {path}",
        "remove_quarantine_ok": "隔離属性を削除しました",
        "remove_quarantine_warn": "警告: 隔離属性の削除に失敗しました",
        "download_only_path": "ダウンロードのみ: {path} に保存されました",
        "install_prepare": "{path} にインストール準備中",
        "requires_admin": "管理者権限が必要です。パスワードを入力してください。",
        "install_complete": "インストール完了",
        "relaunch_warn": "警告: LaunchNext の再起動に失敗しました",
        "release_notes": "リリースノート: {url}",
        "update_complete": "アップデート完了: {tag}",
        "update_elapsed": "処理時間: {seconds} 秒",
        "cancelled": "ユーザーがアップデートをキャンセルしました。",
        "prompt_continue": "{path} にインストールします。続行しますか? [Y/n]: ",
        "prompt_download_only": "ダウンロードのみ実行しますか? [y/N]: ",
        "invalid_choice": "無効な入力です。",
        "download_only_selected": "ダウンロードのみモードを選択しました。",
        "download_and_install": "ダウンロードしてインストールを選択しました。",
        "prompt_language_change": "言語を変更しますか (現在: {lang})? [y/N]: ",
        "press_enter": "閉じるには Enter キーを押してください…",
    },
    "ko": {
        "language_prompt": "언어를 선택하세요:\n  1) English\n  2) 简体中文\n  3) 日本語\n  4) 한국어\n  5) Français\n  6) Español\n  7) Deutsch\n  8) Русский\n  9) हिन्दी\n 10) Tiếng Việt\n선택 [1]: ",
        "language_saved": "언어 설정이 저장되었습니다.",
        "fetching": "릴리스 정보를 가져오는 중: {url}",
        "latest_tag": "최신 릴리스 태그: {tag}",
        "asset_selected": "선택된 에셋: {name} ({size} bytes)",
        "no_asset": "정규식 {pattern} 에 일치하는 에셋이 없습니다.",
        "no_asset_auto": "정규식 {pattern} 에 일치하는 에셋이 없습니다. 사용 가능: {assets}",
        "no_assets_available": "이 릴리스에는 다운로드할 에셋이 없습니다.",
        "asset_fallback": "정규식 {pattern} 에 일치하는 에셋이 없습니다. 아래에서 선택하세요:",
        "prompt_asset_choice": "에셋 선택 [1-{count}] (기본 1): ",
        "downloading": "에셋 다운로드 중…",
        "download_complete": "{path} 에 다운로드 완료 ({size} bytes)",
        "extracting": "압축 해제 중…",
        "found_bundle": "앱 번들을 찾았습니다: {path}",
        "remove_quarantine_ok": "격리 속성을 제거했습니다",
        "remove_quarantine_warn": "경고: 격리 속성 제거 실패",
        "download_only_path": "다운로드 모드: {path} 위치에 저장",
        "install_prepare": "{path} 에 설치 준비 중",
        "requires_admin": "관리자 권한이 필요합니다. 암호를 입력해 주세요.",
        "install_complete": "설치 완료",
        "relaunch_warn": "경고: LaunchNext 자동 실행 실패",
        "release_notes": "릴리스 노트: {url}",
        "update_complete": "업데이트 완료: {tag}",
        "update_elapsed": "소요 시간: {seconds}초",
        "cancelled": "사용자가 업데이트를 취소했습니다.",
        "prompt_continue": "{path} 에 설치합니다. 계속할까요? [Y/n]: ",
        "prompt_download_only": "설치 없이 다운로드만 하시겠습니까? [y/N]: ",
        "invalid_choice": "잘못된 입력입니다.",
        "download_only_selected": "다운로드 전용 모드가 선택되었습니다.",
        "download_and_install": "다운로드 후 설치가 선택되었습니다.",
        "prompt_language_change": "언어를 변경하시겠습니까 (현재: {lang})? [y/N]: ",
        "press_enter": "창을 닫으려면 Enter 키를 누르세요…",
    },
    "fr": {
        "language_prompt": "Sélectionnez la langue :\n  1) English\n  2) 简体中文\n  3) 日本語\n  4) 한국어\n  5) Français\n  6) Español\n  7) Deutsch\n  8) Русский\n  9) हिन्दी\n 10) Tiếng Việt\nEntrez votre choix [1] : ",
        "language_saved": "Préférence linguistique enregistrée.",
        "fetching": "Récupération des métadonnées de la version depuis {url}",
        "latest_tag": "Dernier tag de version : {tag}",
        "asset_selected": "Fichier sélectionné : {name} ({size} octets)",
        "no_asset": "Aucun fichier ne correspond au modèle {pattern}",
        "no_asset_auto": "Aucun fichier ne correspond au modèle {pattern}. Fichiers disponibles : {assets}",
        "no_assets_available": "Cette version ne contient aucun fichier téléchargeable.",
        "asset_fallback": "Aucun fichier ne correspond au modèle {pattern}. Sélectionnez l'un des fichiers suivants :",
        "prompt_asset_choice": "Sélectionnez un fichier [1-{count}] (par défaut 1) : ",
        "downloading": "Téléchargement du fichier…",
        "download_complete": "Téléchargement effectué vers {path} ({size} octets)",
        "extracting": "Extraction de l’archive…",
        "found_bundle": "Application trouvée : {path}",
        "remove_quarantine_ok": "Attributs de quarantaine supprimés",
        "remove_quarantine_warn": "Avertissement : impossible de supprimer les attributs de quarantaine",
        "download_only_path": "Mode téléchargement uniquement : application disponible dans {path}",
        "install_prepare": "Préparation de l’installation dans {path}",
        "requires_admin": "Privilèges administrateur requis. Veuillez saisir votre mot de passe si nécessaire.",
        "install_complete": "Installation terminée",
        "relaunch_warn": "Avertissement : impossible de relancer LaunchNext automatiquement",
        "release_notes": "Notes de version : {url}",
        "update_complete": "Mise à jour terminée : {tag}",
        "update_elapsed": "Mise à jour effectuée en {seconds}s",
        "cancelled": "Mise à jour annulée par l’utilisateur.",
        "prompt_continue": "Procéder à l’installation vers {path} ?",
        "prompt_download_only": "Télécharger sans installer ?",
        "invalid_choice": "Choix invalide.",
        "download_only_selected": "Mode téléchargement uniquement sélectionné.",
        "download_and_install": "Mode téléchargement + installation sélectionné.",
        "prompt_language_change": "Changer de langue (actuelle : {lang}) ?",
        "press_enter": "Appuyez sur Entrée pour fermer cette fenêtre…",
    },
    "es": {
        "language_prompt": "Seleccione el idioma:\n  1) English\n  2) 简体中文\n  3) 日本語\n  4) 한국어\n  5) Français\n  6) Español\n  7) Deutsch\n  8) Русский\n  9) हिन्दी\n 10) Tiếng Việt\nOpción [1]: ",
        "language_saved": "Preferencia de idioma guardada.",
        "fetching": "Obteniendo metadatos de la versión desde {url}",
        "latest_tag": "Etiqueta de la última versión: {tag}",
        "asset_selected": "Recurso seleccionado: {name} ({size} bytes)",
        "no_asset": "No hay recursos que coincidan con el patrón {pattern}",
        "no_asset_auto": "No hay recursos que coincidan con el patrón {pattern}. Disponibles: {assets}",
        "no_assets_available": "Esta versión no contiene recursos descargables.",
        "asset_fallback": "No hay recursos que coincidan con el patrón {pattern}. Elija uno:",
        "prompt_asset_choice": "Seleccione un recurso [1-{count}] (predeterminado 1): ",
        "downloading": "Descargando recurso…",
        "download_complete": "Descarga completada en {path} ({size} bytes)",
        "extracting": "Extrayendo el archivo…",
        "found_bundle": "Aplicación encontrada: {path}",
        "remove_quarantine_ok": "Atributo de cuarentena eliminado",
        "remove_quarantine_warn": "Advertencia: no se pudo eliminar el atributo de cuarentena",
        "download_only_path": "Solo descarga: aplicación disponible en {path}",
        "install_prepare": "Preparando instalación en {path}",
        "requires_admin": "Se requieren privilegios de administrador. Introduzca la contraseña si se le solicita.",
        "install_complete": "Instalación completada",
        "relaunch_warn": "Advertencia: no se pudo relanzar LaunchNext automáticamente",
        "release_notes": "Notas de la versión: {url}",
        "update_complete": "Actualización completada: {tag}",
        "update_elapsed": "Actualización terminada en {seconds} s",
        "cancelled": "Actualización cancelada por el usuario.",
        "prompt_continue": "¿Instalar en {path}? [Y/n]: ",
        "prompt_download_only": "¿Descargar sin instalar? [y/N]: ",
        "invalid_choice": "Opción no válida.",
        "download_only_selected": "Modo solo descarga seleccionado.",
        "download_and_install": "Modo descargar e instalar seleccionado.",
        "prompt_language_change": "¿Cambiar idioma (actual: {lang})? [y/N]: ",
        "press_enter": "Pulse Intro para cerrar esta ventana…",
    },
    "de": {
        "language_prompt": "Sprache auswählen:\n  1) English\n  2) 简体中文\n  3) 日本語\n  4) 한국어\n  5) Français\n  6) Español\n  7) Deutsch\n  8) Русский\n  9) हिन्दी\n 10) Tiếng Việt\nAuswahl [1]: ",
        "language_saved": "Spracheinstellung gespeichert.",
        "fetching": "Versionsinformationen werden von {url} abgerufen",
        "latest_tag": "Neueste Versionskennung: {tag}",
        "asset_selected": "Ausgewählte Datei: {name} ({size} Bytes)",
        "no_asset": "Keine Ressource entspricht dem Muster {pattern}",
        "no_asset_auto": "Keine Ressource entspricht dem Muster {pattern}. Verfügbar: {assets}",
        "no_assets_available": "Diese Version enthält keine herunterladbaren Dateien.",
        "asset_fallback": "Keine Ressource entspricht dem Muster {pattern}. Bitte wählen Sie eine aus:",
        "prompt_asset_choice": "Datei auswählen [1-{count}] (Standard 1): ",
        "downloading": "Datei wird heruntergeladen…",
        "download_complete": "Download abgeschlossen nach {path} ({size} Bytes)",
        "extracting": "Archiv wird entpackt…",
        "found_bundle": "Anwendung gefunden: {path}",
        "remove_quarantine_ok": "Quarantäne-Attribut entfernt",
        "remove_quarantine_warn": "Warnung: Quarantäne-Attribut konnte nicht entfernt werden",
        "download_only_path": "Nur-Download-Modus: App unter {path} verfügbar",
        "install_prepare": "Installation in {path} wird vorbereitet",
        "requires_admin": "Administratorrechte erforderlich. Geben Sie Ihr Passwort ein, wenn Sie dazu aufgefordert werden.",
        "install_complete": "Installation abgeschlossen",
        "relaunch_warn": "Warnung: LaunchNext konnte nicht automatisch neu gestartet werden",
        "release_notes": "Versionshinweise: {url}",
        "update_complete": "Aktualisierung abgeschlossen: {tag}",
        "update_elapsed": "Aktualisierung abgeschlossen in {seconds} s",
        "cancelled": "Aktualisierung vom Benutzer abgebrochen.",
        "prompt_continue": "Nach {path} installieren? [Y/n]: ",
        "prompt_download_only": "Nur herunterladen und nicht installieren? [y/N]: ",
        "invalid_choice": "Ungültige Auswahl.",
        "download_only_selected": "Nur-Download-Modus ausgewählt.",
        "download_and_install": "Download-und-Installations-Modus ausgewählt.",
        "prompt_language_change": "Sprache ändern (aktuell: {lang})? [y/N]: ",
        "press_enter": "Zum Schließen dieses Fensters die Eingabetaste drücken…",
    },
    "ru": {
        "language_prompt": "Выберите язык:\n  1) English\n  2) 简体中文\n  3) 日本語\n  4) 한국어\n  5) Français\n  6) Español\n  7) Deutsch\n  8) Русский\n  9) हिन्दी\n 10) Tiếng Việt\nВведите номер [1]: ",
        "language_saved": "Языковые настройки сохранены.",
        "fetching": "Получение сведений о релизе по адресу {url}",
        "latest_tag": "Текущий тег релиза: {tag}",
        "asset_selected": "Выбранный файл: {name} ({size} байт)",
        "no_asset": "Нет ресурсов, соответствующих шаблону {pattern}",
        "no_asset_auto": "Нет ресурсов, соответствующих шаблону {pattern}. Доступно: {assets}",
        "no_assets_available": "В релизе нет файлов для загрузки.",
        "asset_fallback": "Нет ресурсов, соответствующих шаблону {pattern}. Выберите один из них:",
        "prompt_asset_choice": "Выберите файл [1-{count}] (по умолчанию 1): ",
        "downloading": "Загрузка файла…",
        "download_complete": "Загрузка завершена: {path} ({size} байт)",
        "extracting": "Распаковка архива…",
        "found_bundle": "Найдено приложение: {path}",
        "remove_quarantine_ok": "Атрибут карантина удалён",
        "remove_quarantine_warn": "Предупреждение: не удалось удалить атрибут карантина",
        "download_only_path": "Режим только загрузки: приложение доступно по пути {path}",
        "install_prepare": "Подготовка установки в {path}",
        "requires_admin": "Требуются права администратора. Введите пароль, если будет запрос.",
        "install_complete": "Установка завершена",
        "relaunch_warn": "Предупреждение: не удалось автоматически перезапустить LaunchNext",
        "release_notes": "Описание релиза: {url}",
        "update_complete": "Обновление завершено: {tag}",
        "update_elapsed": "Обновление заняло {seconds} с",
        "cancelled": "Обновление отменено пользователем.",
        "prompt_continue": "Установить в {path}? [Y/n]: ",
        "prompt_download_only": "Скачать без установки? [y/N]: ",
        "invalid_choice": "Неверный выбор.",
        "download_only_selected": "Выбран режим только загрузки.",
        "download_and_install": "Выбран режим загрузки и установки.",
        "prompt_language_change": "Изменить язык (текущий: {lang})? [y/N]: ",
        "press_enter": "Нажмите Enter, чтобы закрыть это окно…",
    },
    "hi": {
        "language_prompt": "भाषा चुनें:\n  1) English\n  2) 简体中文\n  3) 日本語\n  4) 한국어\n  5) Français\n  6) Español\n  7) Deutsch\n  8) Русский\n  9) हिन्दी\n 10) Tiếng Việt\nचयन करें [1]: ",
        "language_saved": "भाषा वरीयता सहेजी गई।",
        "fetching": "{url} से रिलीज़ मेटाडाटा प्राप्त किया जा रहा है",
        "latest_tag": "नवीनतम रिलीज़ टैग: {tag}",
        "asset_selected": "चयनित संसाधन: {name} ({size} बाइट्स)",
        "no_asset": "{pattern} पैटर्न से मेल खाने वाला कोई संसाधन नहीं है",
        "no_asset_auto": "{pattern} पैटर्न से मेल खाने वाला कोई संसाधन नहीं है। उपलब्ध: {assets}",
        "no_assets_available": "इस रिलीज़ में कोई डाउनलोड करने योग्य संसाधन नहीं है।",
        "asset_fallback": "{pattern} पैटर्न से मेल खाने वाला कोई संसाधन नहीं है। कृपया नीचे से चुनें:",
        "prompt_asset_choice": "संसाधन चुनें [1-{count}] (डिफ़ॉल्ट 1): ",
        "downloading": "संसाधन डाउनलोड किया जा रहा है…",
        "download_complete": "{path} पर डाउनलोड पूरा ({size} बाइट्स)",
        "extracting": "आर्काइव निकाला जा रहा है…",
        "found_bundle": "ऐप बंडल मिला: {path}",
        "remove_quarantine_ok": "क्वारंटीन विशेषता हटाई गई",
        "remove_quarantine_warn": "चेतावनी: क्वारंटीन विशेषता हटाने में विफल",
        "download_only_path": "केवल डाउनलोड मोड: ऐप {path} पर उपलब्ध है",
        "install_prepare": "{path} में इंस्टॉल की तैयारी",
        "requires_admin": "प्रशासक अधिकार आवश्यक हैं। अनुरोध होने पर पासवर्ड दर्ज करें।",
        "install_complete": "इंस्टॉलेशन पूरा",
        "relaunch_warn": "चेतावनी: LaunchNext को स्वतः पुनः खोलने में असफल",
        "release_notes": "रिलीज़ नोट्स: {url}",
        "update_complete": "अपडेट पूरा: {tag}",
        "update_elapsed": "अपडेट को {seconds} सेकंड लगे",
        "cancelled": "उपयोगकर्ता ने अपडेट रद्द कर दिया।",
        "prompt_continue": "{path} में इंस्टॉल करें? [Y/n]: ",
        "prompt_download_only": "बिना इंस्टॉल किए केवल डाउनलोड करें? [y/N]: ",
        "invalid_choice": "अमान्य विकल्प।",
        "download_only_selected": "केवल डाउनलोड मोड चुना गया।",
        "download_and_install": "डाउनलोड और इंस्टॉल मोड चुना गया।",
        "prompt_language_change": "भाषा बदलें (वर्तमान: {lang})? [y/N]: ",
        "press_enter": "इस विंडो को बंद करने के लिए Enter दबाएँ…",
    },
    "vi": {
        "language_prompt": "Chọn ngôn ngữ:\n  1) English\n  2) 简体中文\n  3) 日本語\n  4) 한국어\n  5) Français\n  6) Español\n  7) Deutsch\n  8) Русский\n  9) हिन्दी\n 10) Tiếng Việt\nNhập lựa chọn [1]: ",
        "language_saved": "Đã lưu tùy chọn ngôn ngữ.",
        "fetching": "Đang lấy thông tin phát hành từ {url}",
        "latest_tag": "Tag phát hành mới nhất: {tag}",
        "asset_selected": "Tệp đã chọn: {name} ({size} byte)",
        "no_asset": "Không có tệp nào khớp với biểu thức {pattern}",
        "no_asset_auto": "Không có tệp khớp với biểu thức {pattern}. Các tệp sẵn có: {assets}",
        "no_assets_available": "Bản phát hành này không có tệp có thể tải xuống.",
        "asset_fallback": "Không có tệp khớp với biểu thức {pattern}. Hãy chọn một trong các tùy chọn sau:",
        "prompt_asset_choice": "Chọn tệp [1-{count}] (mặc định 1): ",
        "downloading": "Đang tải xuống…",
        "download_complete": "Đã tải xuống {path} ({size} byte)",
        "extracting": "Đang giải nén gói…",
        "found_bundle": "Đã tìm thấy ứng dụng: {path}",
        "remove_quarantine_ok": "Đã xóa thuộc tính cách ly",
        "remove_quarantine_warn": "Cảnh báo: Không thể xóa thuộc tính cách ly",
        "download_only_path": "Chỉ tải xuống: ứng dụng nằm tại {path}",
        "install_prepare": "Đang chuẩn bị cài đặt vào {path}",
        "requires_admin": "Cần quyền quản trị. Nhập mật khẩu khi được yêu cầu.",
        "install_complete": "Cài đặt hoàn tất",
        "relaunch_warn": "Cảnh báo: Không thể mở lại LaunchNext tự động",
        "release_notes": "Ghi chú phát hành: {url}",
        "update_complete": "Cập nhật hoàn tất: {tag}",
        "update_elapsed": "Hoàn tất sau {seconds} giây",
        "cancelled": "Người dùng đã hủy cập nhật.",
        "prompt_continue": "Cài đặt vào {path}? [Y/n]: ",
        "prompt_download_only": "Chỉ tải xuống mà không cài đặt? [y/N]: ",
        "invalid_choice": "Lựa chọn không hợp lệ.",
        "download_only_selected": "Đã chọn chế độ chỉ tải xuống.",
        "download_and_install": "Đã chọn chế độ tải xuống và cài đặt.",
        "prompt_language_change": "Thay đổi ngôn ngữ (hiện tại: {lang})? [y/N]: ",
        "press_enter": "Nhấn Enter để đóng cửa sổ này…",
    },
}

LANG_CODES = {
    "1": "en",
    "2": "zh",
    "3": "ja",
    "4": "ko",
    "5": "fr",
    "6": "es",
    "7": "de",
    "8": "ru",
    "9": "hi",
    "10": "vi",
}
ALLOWED_LANG_CODES = set(LANG_CODES.values())
LANG_MENU_ORDER = [LANG_CODES[key] for key in sorted(LANG_CODES, key=lambda x: int(x))]
SUPPORTED_LANG_LIST = list(LANG_MENU_ORDER)
LANG_DISPLAY_NAMES = {
    "en": "English",
    "zh": "简体中文",
    "ja": "日本語",
    "ko": "한국어",
    "fr": "Français",
    "es": "Español",
    "de": "Deutsch",
    "ru": "Русский",
    "hi": "हिन्दी",
    "vi": "Tiếng Việt",
}
LANGUAGE_HINTS = {
    "en": "Use ↑/↓ to choose, Enter to confirm, Q to cancel",
    "zh": "使用 ↑/↓ 选择，Enter 确认，Q 取消",
    "ja": "↑↓ で移動、Enter で決定、Q で戻る",
    "ko": "↑↓ 키로 선택, Enter 확인, Q 취소",
    "fr": "↑/↓ pour choisir, Entrée pour valider, Q pour annuler",
    "es": "↑/↓ para elegir, Enter para confirmar, Q para cancelar",
    "de": "Mit ↑/↓ wählen, Enter bestätigen, Q zum Abbrechen",
    "ru": "↑/↓ — выбор, Enter — подтвердить, Q — отменить",
    "hi": "↑/↓ से चुनें, Enter से पुष्टि करें, Q से रद्द करें",
    "vi": "Dùng ↑/↓ chọn, Enter xác nhận, Q huỷ",
}
YES_NO_LABELS = {
    "zh": ("是", "否"),
    "ja": ("はい", "いいえ"),
    "ko": ("예", "아니오"),
    "fr": ("Oui", "Non"),
    "es": ("Sí", "No"),
    "de": ("Ja", "Nein"),
    "ru": ("Да", "Нет"),
    "hi": ("हाँ", "नहीं"),
    "vi": ("Có", "Không"),
}
YES_NO_HINTS = {
    "en": "Use ←/→ to choose, Enter to confirm",
    "zh": "使用 ←/→ 切换，Enter 确认",
    "ja": "←→ で切替、Enter で決定",
    "ko": "←→ 로 선택, Enter 확인",
    "fr": "←/→ pour choisir, Entrée pour valider",
    "es": "←/→ para elegir, Enter para confirmar",
    "de": "←/→ zum Wählen, Enter bestätigt",
    "ru": "←/→ для выбора, Enter — подтвердить",
    "hi": "←→ से चुनें, Enter से पुष्टि करें",
    "vi": "Dùng ←→ chọn, Enter xác nhận",
}
DEFAULT_LANG = "en"


def safe_addstr(stdscr, y: int, x: int, text: str, attr: int = 0) -> None:
    try:
        stdscr.addstr(y, x, text, attr)
    except curses.error:
        pass


def wrap_message(message: str, width: int) -> list[str]:
    if width <= 0:
        return [message]
    wrapped = textwrap.wrap(message, width)
    if not wrapped:
        return [message[:width]]
    return wrapped


class UpdaterError(Exception):
    pass


def load_config(config_path: Path) -> dict:
    if config_path.exists():
        try:
            data = json.loads(config_path.read_text(encoding="utf-8"))
            if isinstance(data, dict):
                data.pop("supported_languages", None)
                return data
        except Exception:
            return {}
    return {}


def save_config(config_path: Path, data: dict) -> None:
    payload = dict(data)
    payload["supported_languages"] = SUPPORTED_LANG_LIST
    config_path.parent.mkdir(parents=True, exist_ok=True)
    config_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")


def ensure_language(strings: dict, lang: str) -> dict:
    return strings.get(lang, strings[DEFAULT_LANG])


def choose_language(config: dict, args, strings) -> str:
    if args.reset_language:
        config.pop("language", None)
    if args.language:
        return args.language
    saved = config.get("language") if isinstance(config, dict) else None
    if saved in ALLOWED_LANG_CODES:
        return saved
    return DEFAULT_LANG


def timestamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


class Logger:
    def __init__(self, path: Path, display=None):
        self.path = path
        self.display = display
        path.parent.mkdir(parents=True, exist_ok=True)
        if not path.exists():
            path.touch()

    def log(self, message: str) -> None:
        line = f"{timestamp()} {message}"
        if self.display:
            self.display.log_line(line)
        else:
            print(line)
        with self.path.open("a", encoding="utf-8") as fh:
            fh.write(line + "\n")

    def pause_for_external(self) -> None:
        if self.display:
            self.display.pause_for_external()

    def resume_after_external(self) -> None:
        if self.display:
            self.display.resume_after_external()

def fetch_release_metadata(tag: Optional[str], headers: dict) -> dict:
    if tag:
        url = f"https://api.github.com/repos/{REPO_OWNER}/{REPO_NAME}/releases/tags/{tag}"
    else:
        url = f"https://api.github.com/repos/{REPO_OWNER}/{REPO_NAME}/releases/latest"
    request = urllib.request.Request(url, headers=headers)
    with urllib.request.urlopen(request) as response:
        if response.status != 200:
            raise UpdaterError(f"GitHub API returned status {response.status}")
        return json.load(response)


def select_asset(
    metadata: dict, pattern: str, strings: dict, interactive: bool
) -> tuple[str, str, int, str, str]:
    regex = re.compile(pattern)
    for asset in metadata.get("assets", []):
        name = asset.get("name")
        if name and regex.search(name):
            url = asset.get("browser_download_url") or ""
            size = asset.get("size", 0)
            return name, url, size, metadata.get("tag_name", ""), metadata.get("html_url", "")

    assets = metadata.get("assets", [])
    if not assets:
        raise UpdaterError(strings["no_assets_available"])

    if not interactive:
        asset_names = ", ".join(asset.get("name", "?") for asset in assets)
        raise UpdaterError(strings["no_asset_auto"].format(pattern=pattern, assets=asset_names))

    print(strings["asset_fallback"].format(pattern=pattern))
    for idx, asset in enumerate(assets, 1):
        name = asset.get("name", "?")
        size = asset.get("size", 0)
        print(f"  {idx}) {name} ({size} bytes)")

    while True:
        choice = input(strings["prompt_asset_choice"].format(count=len(assets))).strip()
        if not choice:
            choice = "1"
        if choice.isdigit() and 1 <= int(choice) <= len(assets):
            selected = assets[int(choice) - 1]
            name = selected.get("name", "?")
            url = selected.get("browser_download_url") or ""
            size = selected.get("size", 0)
            return name, url, size, metadata.get("tag_name", ""), metadata.get("html_url", "")
        print(strings["invalid_choice"])


class CursesSession:
    def __init__(self, stdscr):
        self.stdscr = stdscr
        self.status_line: Optional[str] = None
        self.footer: Optional[str] = None
        self.title = "LaunchNext Updater"
        self.progress_label: Optional[str] = None
        self.progress_current: int = 0
        self.progress_total: int = 0
        self.color_normal = 0
        self.attr_normal = curses.A_NORMAL
        self.attr_bold = curses.A_BOLD
        self.attr_dim = curses.A_DIM
        self.attr_highlight = curses.A_REVERSE
        try:
            if curses.has_colors():
                curses.start_color()
                curses.use_default_colors()
                curses.init_pair(1, curses.COLOR_WHITE, -1)
                self.color_normal = curses.color_pair(1)
                self.attr_normal |= self.color_normal
                self.attr_bold |= self.color_normal
                self.attr_dim |= self.color_normal
                self.attr_highlight = curses.A_REVERSE | self.color_normal
        except curses.error:
            pass
        stdscr.keypad(True)
        try:
            curses.curs_set(0)
        except curses.error:
            pass
        self.stdscr.bkgd(" ", self.color_normal)
        self.stdscr.clear()

    def _refresh(self) -> None:
        self.stdscr.erase()
        self.stdscr.bkgd(" ", self.color_normal)
        height, width = self.stdscr.getmaxyx()
        safe_addstr(self.stdscr, 0, 2, self.title[: max(0, width - 4)], self.attr_bold)
        cursor_row = 2
        if self.status_line:
            lines = wrap_message(self.status_line, max(1, width - 4))
            for idx, line in enumerate(lines):
                safe_addstr(self.stdscr, cursor_row + idx, 2, line[: max(0, width - 4)], self.attr_normal)
            cursor_row += len(lines)
        if self.progress_label:
            total = self.progress_total or 0
            current = self.progress_current
            if total > 0:
                percent = int(min(100, max(0, current * 100 / total)))
                ratio = min(1.0, max(0.0, current / total))
                label_text = f"{self.progress_label} {percent:3d}% ({current / (1024 * 1024):.1f}/{total / (1024 * 1024):.1f} MB)"
            else:
                ratio = 0.0
                label_text = f"{self.progress_label} {current / (1024 * 1024):.1f} MB"
            safe_addstr(self.stdscr, cursor_row, 2, label_text[: max(0, width - 4)], self.attr_dim)
            bar_width = max(10, width - 4)
            filled = int(bar_width * ratio)
            bar = "█" * filled + " " * (bar_width - filled)
            safe_addstr(self.stdscr, cursor_row + 1, 2, bar[: max(0, width - 4)], self.attr_highlight)
            cursor_row += 2
        if self.footer:
            safe_addstr(self.stdscr, height - 2, 2, self.footer[: max(0, width - 4)], self.attr_dim)
        self.stdscr.refresh()

    def log_line(self, line: str) -> None:
        self.status_line = line
        self._refresh()

    def pause_for_external(self) -> None:
        curses.def_prog_mode()
        curses.endwin()

    def resume_after_external(self) -> None:
        curses.reset_prog_mode()
        self._refresh()

    def wait_for_exit(self, prompt: str) -> None:
        self.footer = prompt
        self._refresh()
        self.stdscr.getch()
        self.footer = None

    def reset_log(self) -> None:
        self.status_line = None
        self.footer = None
        self.clear_progress()

    def clear_progress(self) -> None:
        self.progress_label = None
        self.progress_current = 0
        self.progress_total = 0
        self._refresh()

    def update_progress(self, label: str, current: int, total: Optional[int]) -> None:
        self.progress_label = label
        self.progress_current = current
        self.progress_total = total or 0
        self._refresh()

    def select_language(self, default_code: Optional[str], label_strings: dict) -> str:
        options = [(code, LANG_DISPLAY_NAMES.get(code, code)) for code in LANG_MENU_ORDER]
        try:
            index = next(i for i, (code, _) in enumerate(options) if code == default_code)
        except StopIteration:
            index = 0

        while True:
            self.stdscr.erase()
            self.stdscr.bkgd(" ", self.color_normal)
            height, width = self.stdscr.getmaxyx()
            prompt_lines = label_strings.get("language_prompt", "Select language:").split("\n")
            if prompt_lines:
                safe_addstr(self.stdscr, 1, 2, prompt_lines[0][: max(0, width - 4)], self.attr_bold)
            current_lang = options[index][0]
            hint_text = LANGUAGE_HINTS.get(current_lang, LANGUAGE_HINTS[DEFAULT_LANG])
            safe_addstr(self.stdscr, height - 2, 2, hint_text[: max(0, width - 4)], self.attr_dim)
            for offset, (code, label) in enumerate(options):
                line = f"{label} ({code})"
                attr = self.attr_highlight if offset == index else self.attr_normal
                safe_addstr(self.stdscr, 3 + offset, 4, line[: max(0, width - 8)], attr)
            self.stdscr.refresh()
            key = self.stdscr.getch()
            if key in (curses.KEY_UP, ord("k"), ord("K")):
                index = (index - 1) % len(options)
            elif key in (curses.KEY_DOWN, ord("j"), ord("J")):
                index = (index + 1) % len(options)
            elif key in (curses.KEY_ENTER, 10, 13):
                return options[index][0]
            elif key in (27, ord("q"), ord("Q")):
                return options[index][0]

    def prompt_yes_no(
        self,
        message: str,
        default_yes: bool = True,
        hint: Optional[str] = None,
        yes_label: str = "Yes",
        no_label: str = "No",
    ) -> bool:
        selected = 0 if default_yes else 1
        options = [(True, yes_label), (False, no_label)]
        if hint is None:
            hint = YES_NO_HINTS.get(DEFAULT_LANG)

        while True:
            self.stdscr.erase()
            self.stdscr.bkgd(" ", self.color_normal)
            height, width = self.stdscr.getmaxyx()
            lines = wrap_message(message, width - 4)
            for idx, line in enumerate(lines):
                safe_addstr(self.stdscr, 2 + idx, 2, line, self.attr_normal)
            if hint:
                safe_addstr(self.stdscr, 4 + len(lines), 2, hint[: max(0, width - 4)], self.attr_dim)
            base_y = 6 + len(lines)
            x_pos = 4
            for idx, (value, label) in enumerate(options):
                block = f"[ {label} ]"
                attr = self.attr_highlight if idx == selected else self.attr_normal
                safe_addstr(self.stdscr, base_y, x_pos, block[: max(0, width - x_pos - 1)], attr)
                x_pos += len(block) + 2
            self.stdscr.refresh()
            key = self.stdscr.getch()
            if key in (curses.KEY_LEFT, ord("h"), ord("H")):
                selected = (selected - 1) % len(options)
            elif key in (curses.KEY_RIGHT, ord("l"), ord("L")):
                selected = (selected + 1) % len(options)
            elif key in (curses.KEY_ENTER, 10, 13):
                return options[selected][0]
            elif key in (27,):
                return options[selected][0]


def download_asset(
    url: str,
    dest: Path,
    logger: Logger,
    strings: dict,
    progress_callback=None,
    expected_size: Optional[int] = None,
) -> int:
    request = urllib.request.Request(url)
    total_bytes = 0
    with urllib.request.urlopen(request) as response, dest.open("wb") as out:
        chunk_size = 1024 * 512
        while True:
            chunk = response.read(chunk_size)
            if not chunk:
                break
            out.write(chunk)
            total_bytes += len(chunk)
            if progress_callback:
                progress_callback(total_bytes, expected_size)
    if progress_callback:
        progress_callback(expected_size or total_bytes, expected_size)
    logger.log(strings["download_complete"].format(path=dest, size=total_bytes))
    return total_bytes


def run_subprocess(args: list[str], logger: Logger, error_message: str, elevate: bool = False) -> None:
    try:
        subprocess.run(args, check=True)
    except subprocess.CalledProcessError as exc:
        logger.log(f"{error_message}: {exc}")
        raise UpdaterError(error_message) from exc


def remove_quarantine(bundle: Path, logger: Logger, strings: dict) -> None:
    try:
        subprocess.run(["xattr", "-dr", "com.apple.quarantine", str(bundle)], check=True)
        logger.log(strings["remove_quarantine_ok"])
    except subprocess.CalledProcessError:
        logger.log(strings["remove_quarantine_warn"])


def install_bundle(bundle: Path, target: Path, logger: Logger, strings: dict) -> None:
    logger.log(strings["install_prepare"].format(path=target))

    def do_install():
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.exists():
            shutil.rmtree(target)
        subprocess.run([
            "ditto",
            "--rsrc",
            "--preserveHFSCompression",
            str(bundle),
            str(target),
        ], check=True)

    needs_privilege = not str(target).startswith(str(Path.home()))
    if needs_privilege:
        logger.log(strings["requires_admin"])
        with tempfile.NamedTemporaryFile("w", delete=False, suffix=".sh") as tmp:
            tmp.write(
                f"#!/bin/bash\n"
                "set -euo pipefail\n"
                f"mkdir -p \"{target.parent}\"\n"
                f"rm -rf \"{target}\"\n"
                f"ditto --rsrc --preserveHFSCompression \"{bundle}\" \"{target}\"\n"
            )
            temp_path = Path(tmp.name)
        temp_path.chmod(0o755)
        try:
            logger.pause_for_external()
            run_subprocess([
                "sudo",
                "/bin/bash",
                str(temp_path),
            ], logger, "Administrator install failed", elevate=True)
        finally:
            logger.resume_after_external()
            temp_path.unlink(missing_ok=True)
    else:
        try:
            do_install()
        except subprocess.CalledProcessError as exc:
            raise UpdaterError("Installation failed") from exc


def emit_json(stage: str, message: str, elapsed: float) -> None:
    print(json.dumps({
        "stage": stage,
        "message": message,
        "elapsed_seconds": elapsed,
    }))


def execute_update(
    args,
    strings: dict,
    install_dir: Path,
    download_only: bool,
    logger: Logger,
    base_dir: Path,
    hold_window: bool,
    hold_callback=None,
    allow_manual_choice: bool = True,
    display=None,
) -> int:
    headers = {"Accept": "application/vnd.github+json"}
    token = os.environ.get("GITHUB_TOKEN")
    if token:
        headers["Authorization"] = f"Bearer {token}"

    start_time = datetime.now()

    try:
        api_url = (
            f"https://api.github.com/repos/{REPO_OWNER}/{REPO_NAME}/releases/tags/{args.tag}"
            if args.tag
            else f"https://api.github.com/repos/{REPO_OWNER}/{REPO_NAME}/releases/latest"
        )
        logger.log(strings["fetching"].format(url=api_url))
        metadata = fetch_release_metadata(args.tag, headers)
        release_tag = metadata.get("tag_name", "unknown")
        release_url = metadata.get("html_url", "")
        logger.log(strings["latest_tag"].format(tag=release_tag))

        asset_name, asset_url, asset_size, release_tag, release_url = select_asset(
            metadata,
            args.asset_pattern,
            strings,
            allow_manual_choice and not args.yes,
        )
        logger.log(strings["asset_selected"].format(name=asset_name, size=asset_size))
        expected_size = asset_size or None

        with tempfile.TemporaryDirectory() as tmp_dir_str:
            tmp_dir = Path(tmp_dir_str)
            archive_path = tmp_dir / asset_name
            logger.log(strings["downloading"])
            progress_cb = None
            if display and hasattr(display, "update_progress"):
                label = strings.get("downloading", "Downloading...")

                def _progress(current: int, total: Optional[int]) -> None:
                    display.update_progress(label, current, total)

                progress_cb = _progress
            download_asset(
                asset_url,
                archive_path,
                logger,
                strings,
                progress_callback=progress_cb,
                expected_size=expected_size,
            )
            if display and hasattr(display, "clear_progress"):
                display.clear_progress()

            logger.log(strings["extracting"])
            extract_dir = tmp_dir / "extracted"
            extract_dir.mkdir(parents=True, exist_ok=True)
            run_subprocess([
                "ditto",
                "-x",
                "-k",
                str(archive_path),
                str(extract_dir),
            ], logger, "Failed to extract archive")

            app_candidates = list(extract_dir.rglob("*.app"))
            if not app_candidates:
                raise UpdaterError("Archive does not contain a .app bundle")
            app_bundle = app_candidates[0]
            logger.log(strings["found_bundle"].format(path=app_bundle))

            remove_quarantine(app_bundle, logger, strings)

            downloads_dir = base_dir / DOWNLOADS_SUBDIR
            downloads_dir.mkdir(parents=True, exist_ok=True)

            if download_only:
                target_copy = downloads_dir / f"{asset_name.rstrip('.zip')}.app"
                if target_copy.exists():
                    shutil.rmtree(target_copy)
                run_subprocess([
                    "ditto",
                    "--rsrc",
                    "--preserveHFSCompression",
                    str(app_bundle),
                    str(target_copy),
                ], logger, "Failed to copy bundle to downloads directory")
                logger.log(strings["download_only_path"].format(path=target_copy))
                message = strings["download_only_path"].format(path=target_copy)
            else:
                install_bundle(app_bundle, install_dir, logger, strings)
                message = strings["update_complete"].format(tag=release_tag)
                logger.log(strings["install_complete"])
                if release_url:
                    logger.log(strings["release_notes"].format(url=release_url))
                if subprocess.run(["open", str(install_dir)], check=False).returncode != 0:
                    logger.log(strings["relaunch_warn"])

        elapsed = (datetime.now() - start_time).total_seconds()
        logger.log(strings["update_elapsed"].format(seconds=int(elapsed)))

        if args.emit_json:
            emit_json("Finished", message, elapsed)
        if hold_window:
            if hold_callback:
                hold_callback(strings["press_enter"])
            else:
                wait_for_enter(strings)
        return 0

    except UpdaterError as err:
        if display and hasattr(display, "clear_progress"):
            display.clear_progress()
        logger.log(f"ERROR: {err}")
        if args.emit_json:
            emit_json("Failed", str(err), (datetime.now() - start_time).total_seconds())
        if hold_window:
            if hold_callback:
                hold_callback(strings["press_enter"])
            else:
                wait_for_enter(strings)
        return 1


def main() -> int:
    parser = argparse.ArgumentParser(description="LaunchNext updater")
    parser.add_argument("--tag")
    parser.add_argument("--asset-pattern", default=DEFAULT_PATTERN)
    parser.add_argument("--install-dir")
    parser.add_argument("--download-only", action="store_true")
    parser.add_argument("--emit-json", action="store_true")
    parser.add_argument("--yes", action="store_true", help="Run without prompts")
    parser.add_argument("--language", choices=list(STRINGS.keys()))
    parser.add_argument("--reset-language", action="store_true")
    parser.add_argument("--hold-window", action="store_true")
    args = parser.parse_args()

    base_dir = Path.home() / "Library" / "Application Support" / "LaunchNext" / "updates"
    log_path = base_dir / LOG_NAME
    config_path = base_dir / CONFIG_NAME
    config = load_config(config_path)
    install_dir = Path(args.install_dir or DEFAULT_INSTALL)

    interactive_mode = sys.stdin.isatty() and not args.yes and not args.emit_json
    download_only_mode = args.download_only

    if interactive_mode:
        result: dict[str, int] = {"code": 0}

        def _interactive(stdscr):
            session = CursesSession(stdscr)
            saved_lang = config.get("language") if isinstance(config, dict) else None
            if args.reset_language:
                saved_lang = None
            lang_candidate = args.language or (saved_lang if saved_lang in ALLOWED_LANG_CODES else None)
            label_strings = ensure_language(STRINGS, lang_candidate or DEFAULT_LANG)
            lang_code = session.select_language(lang_candidate, label_strings)
            if lang_code not in ALLOWED_LANG_CODES:
                lang_code = DEFAULT_LANG
            strings = ensure_language(STRINGS, lang_code)
            config["language"] = lang_code
            save_config(config_path, config)
            session.title = strings.get("appTitle", session.title)

            yes_label, no_label = YES_NO_LABELS.get(lang_code, ("Yes", "No"))
            hint_text = YES_NO_HINTS.get(lang_code, YES_NO_HINTS.get(DEFAULT_LANG))
            proceed = session.prompt_yes_no(
                strings["prompt_continue"].format(path=install_dir),
                default_yes=True,
                hint=hint_text,
                yes_label=yes_label,
                no_label=no_label,
            )
            logger = Logger(log_path, display=session)
            session.reset_log()

            if not proceed:
                logger.log(strings["cancelled"])
                if args.emit_json:
                    emit_json("Cancelled", strings["cancelled"], 0.0)
                session.wait_for_exit(strings["press_enter"])
                result["code"] = 0
                return

            exit_code = execute_update(
                args,
                strings,
                install_dir,
                download_only_mode,
                logger,
                base_dir,
                hold_window=True,
                hold_callback=session.wait_for_exit,
                allow_manual_choice=False,
                display=session,
            )
            result["code"] = exit_code

        curses.wrapper(_interactive)
        return result["code"]

    if args.reset_language:
        config.pop("language", None)

    lang_code = choose_language(config, args, STRINGS)
    if lang_code not in ALLOWED_LANG_CODES:
        lang_code = DEFAULT_LANG
    strings = ensure_language(STRINGS, lang_code)
    config["language"] = lang_code
    save_config(config_path, config)

    logger = Logger(log_path)

    hold_window = args.hold_window

    if not args.yes:
        answer = input(strings["prompt_continue"].format(path=install_dir)).strip().lower()
        if answer in {"n", "no"}:
            logger.log(strings["cancelled"])
            if args.emit_json:
                emit_json("Cancelled", strings["cancelled"], 0.0)
            return 0
        if not download_only_mode:
            choice = input(strings["prompt_download_only"]).strip().lower()
            if choice in {"y", "yes"}:
                download_only_mode = True

    return execute_update(
        args,
        strings,
        install_dir,
        download_only_mode,
        logger,
        base_dir,
        hold_window,
    )

if __name__ == "__main__":
    sys.exit(main())
