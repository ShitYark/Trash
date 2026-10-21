import Foundation

/// Как удалить элемент через его менеджер, а не файлами. Заполняет только сканер — из вывода самого менеджера;
/// перед запуском `ManagerRemover` ещё раз проверяет идентификатор и свежее состояние.
enum ManagerRemoval: Hashable, Sendable {
    /// `simctl delete <udid>`.
    case simulator(udid: String)
    /// `simctl runtime delete <identifier>`; `runtimeIdentifier` — чтобы проверить, не пользуются ли им симуляторы.
    case runtime(identifier: String, runtimeIdentifier: String)
    /// `brew uninstall <формула>` — зависимость, которая больше ничему не нужна, целиком.
    case brewUninstall(formula: String)
    /// `brew cleanup <формула>` — все старые версии формулы разом.
    case brewCleanup(formula: String)
    /// `docker … prune -f` — неиспользуемое одного вида внутри диска Docker Desktop.
    case dockerPrune(DockerTarget)
    /// `<база>/bin/conda remove -p <окружение> --all -y`.
    case condaRemoveEnvironment(conda: String, prefix: String)
    /// `<база>/bin/conda clean --all -y` — все кэши пакетов, которые знает эта conda.
    case condaClean(conda: String)
    /// `DELETE /api/delete` к локальному серверу Ollama — как `ollama rm`.
    case ollamaDelete(model: String)
    /// `port -N uninstall <порт> @<версия>` — неактивная версия порта MacPorts.
    case portUninstall(name: String, version: String)
    /// `simctl runtime dyld_shared_cache remove <runtimeIdentifier>/<сборка>` — кэш dyld одного рантайма.
    case dyldCacheRemove(runtimeIdentifier: String, build: String)

    /// Что внутри диска Docker чистит команда.
    enum DockerTarget: String, Hashable, Sendable {
        /// `docker container prune -f` — остановленные контейнеры.
        case containers
        /// `docker image prune -a -f` — образы без контейнеров.
        case images
        /// `docker builder prune -a -f` — кэш сборки, который сейчас не используется.
        case buildCache
    }

    /// Раздел, к которому операция относится: операция у элемента чужого раздела — отказ.
    var category: CleanupCategory {
        switch self {
        case .simulator: .simulators
        case .runtime: .simulatorRuntimes
        case .brewUninstall, .brewCleanup: .homebrew
        case .dockerPrune: .docker
        case .condaRemoveEnvironment, .condaClean: .conda
        case .ollamaDelete: .ollama
        case .portUninstall: .macPorts
        case .dyldCacheRemove: .simulatorDyldCaches
        }
    }

    /// Чем удаляется — для текстов окна очистки.
    var tool: String {
        switch self {
        case .simulator, .runtime, .dyldCacheRemove: "simctl"
        case .brewUninstall, .brewCleanup: "brew"
        case .dockerPrune: "docker"
        case .condaRemoveEnvironment, .condaClean: "conda"
        case .ollamaDelete: "Ollama"
        case .portUninstall: "port"
        }
    }

    /// Одна команда удаляет сразу несколько элементов — их отметки связаны: что видно отмеченным, то и удалится.
    /// `conda clean --all` чистит все кэши пакетов этой conda, включая `~/.conda/pkgs`.
    var isGrouped: Bool {
        switch self {
        case .brewUninstall, .brewCleanup, .condaClean: true
        case .simulator, .runtime, .dockerPrune, .condaRemoveEnvironment, .ollamaDelete, .portUninstall, .dyldCacheRemove: false
        }
    }

    /// Команда удаляет файлы по путям элементов — после неё проверяется, исчезли ли они. `simctl` знает сам;
    /// кэш conda и диск Docker остаются на месте — чистится их содержимое. Ollama удаляет по имени в своей папке
    /// моделей — остался отсканированный манифест, значит, удалила не его.
    var isCheckedByPath: Bool {
        switch self {
        case .brewUninstall, .brewCleanup, .condaRemoveEnvironment, .ollamaDelete, .dyldCacheRemove: true
        case .simulator, .runtime, .dockerPrune, .condaClean, .portUninstall: false
        }
    }
}
