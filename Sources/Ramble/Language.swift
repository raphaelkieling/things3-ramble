import Foundation

enum RambleLanguage: String, CaseIterable {
    case portuguese = "pt"
    case english = "en"
    case spanish = "es"

    static let preference = "interfaceLanguage"
    static var current: Self {
        UserDefaults.standard.string(forKey: preference).flatMap(Self.init(rawValue:)) ?? .portuguese
    }

    var name: String {
        switch self {
        case .portuguese: "Português"
        case .english: "English"
        case .spanish: "Español"
        }
    }

    var speechLocale: Locale {
        switch self {
        case .portuguese: Locale(identifier: "pt-BR")
        case .english: Locale(identifier: "en-US")
        case .spanish: Locale(identifier: "es-ES")
        }
    }
}

func tr(_ source: String) -> String {
    switch RambleLanguage.current {
    case .portuguese: return source
    case .english: return translations[source]?.english ?? source
    case .spanish: return translations[source]?.spanish ?? source
    }
}

private let translations: [String: (english: String, spanish: String)] = [
    "Modelo da Apple instalado.": ("Apple speech model installed.", "Modelo de Apple instalado."),
    "Modelo da Apple em download…": ("Downloading Apple speech model…", "Descargando el modelo de Apple…"),
    "O modelo da Apple será baixado na primeira captura neste idioma.": ("The Apple model downloads on the first capture in this language.", "El modelo de Apple se descarga en la primera captura en este idioma."),
    "Vocabulário personalizado": ("Custom vocabulary", "Vocabulario personalizado"),
    "Um termo por linha, até 120 caracteres. No modo GPT, a lista vai para a OpenAI.": ("One term per line, up to 120 characters. GPT mode sends the list to OpenAI.", "Un término por línea, hasta 120 caracteres. El modo GPT envía la lista a OpenAI."),
    "Registrar tempos localmente": ("Record timings locally", "Registrar tiempos localmente"),
    "Ajustes": ("Settings", "Ajustes"),
    "Ajustes…": ("Settings…", "Ajustes…"),
    "Idioma": ("Language", "Idioma"),
    "Editar": ("Edit", "Editar"),
    "Desfazer": ("Undo", "Deshacer"),
    "Recortar": ("Cut", "Cortar"),
    "Copiar": ("Copy", "Copiar"),
    "Colar": ("Paste", "Pegar"),
    "Selecionar tudo": ("Select All", "Seleccionar todo"),
    "Capturar voz": ("Capture Voice", "Capturar voz"),
    "Capturar voz (atalho indisponível)": ("Capture Voice (shortcut unavailable)", "Capturar voz (atajo no disponible)"),
    "Encerrar Ramble": ("Quit Ramble", "Salir de Ramble"),
    "Captura do Ramble": ("Ramble Capture", "Captura de Ramble"),
    "Chave da API da OpenAI": ("OpenAI API key", "Clave de API de OpenAI"),
    "A OpenAI extrai as tarefas do texto. A opção GPT também envia o áudio à OpenAI.": ("OpenAI extracts tasks from the text. The GPT option also sends audio to OpenAI.", "OpenAI extrae las tareas del texto. La opción GPT también envía el audio a OpenAI."),
    "Transcrição": ("Transcription", "Transcripción"),
    "Apple (no Mac)": ("Apple (on Mac)", "Apple (en el Mac)"),
    "Mostrar transcrição ao vivo": ("Show live transcript", "Mostrar transcripción en directo"),
    "A transcrição da Apple não está disponível neste Mac. Escolha GPT.": ("Apple transcription is unavailable on this Mac. Choose GPT.", "La transcripción de Apple no está disponible en este Mac. Elige GPT."),
    "A transcrição da Apple não está disponível para este idioma ou Mac. Escolha GPT nos Ajustes.": ("Apple transcription is unavailable for this language or Mac. Choose GPT in Settings.", "La transcripción de Apple no está disponible para este idioma o Mac. Elige GPT en Ajustes."),
    "Token de URL do Things 3": ("Things 3 URL token", "Token de URL de Things 3"),
    "Cole o token do Things": ("Paste the Things token", "Pega el token de Things"),
    "No Things, abra Ajustes → Geral → Ativar URLs do Things → Gerenciar.": ("In Things, go to Settings → General → Enable Things URLs → Manage.", "En Things, ve a Ajustes → General → Activar URLs de Things → Gestionar."),
    "Salvos nas Chaves do macOS": ("Saved in macOS Keychain", "Guardados en el llavero de macOS"),
    "Salvar": ("Save", "Guardar"),
    "Prévia das tarefas": ("Task preview", "Vista previa de las tareas"),
    "Cancelar (Esc)": ("Cancel (Esc)", "Cancelar (Esc)"),
    "Cancelar captura": ("Cancel capture", "Cancelar captura"),
    "Prévia indisponível": ("Preview unavailable", "Vista previa no disponible"),
    "Gravando": ("Recording", "Grabando"),
    "Preparando transcrição…": ("Preparing transcription…", "Preparando la transcripción…"),
    "Finalizando…": ("Finishing…", "Finalizando…"),
    "Revise as tarefas": ("Review tasks", "Revisa las tareas"),
    "Enviando ao Things…": ("Sending to Things…", "Enviando a Things…"),
    "Adicionar ao Things (Enter)": ("Add to Things (Enter)", "Añadir a Things (Intro)"),
    "Adicionar ao Things": ("Add to Things", "Añadir a Things"),
    "Prazo": ("Deadline", "Fecha límite"),
    "Recolher detalhes": ("Hide details", "Ocultar detalles"),
    "Mostrar detalhes": ("Show details", "Mostrar detalles"),
    "Remover tarefa": ("Remove task", "Eliminar tarea"),
    "Caixa de Entrada": ("Inbox", "Bandeja de entrada"),
    "Agendada para": ("Scheduled for", "Programada para"),
    "Sem projeto ou área": ("No project or area", "Sin proyecto ni área"),
    "Carregar projetos e áreas": ("Load projects and areas", "Cargar proyectos y áreas"),
    "Carregando projetos e áreas…": ("Loading projects and areas…", "Cargando proyectos y áreas…"),
    "Nenhum projeto ou área": ("No projects or areas", "No hay proyectos ni áreas"),
    "Tentar novamente": ("Try again", "Intentar de nuevo"),
    "Escolher destino no Things": ("Choose a destination in Things", "Elegir un destino en Things"),
    "Instale o Things para escolher projetos e áreas.": ("Install Things to choose projects and areas.", "Instala Things para elegir proyectos y áreas."),
    "Permita o acesso ao Things em Privacidade e Segurança → Automação.": ("Allow access to Things in Privacy & Security → Automation.", "Permite el acceso a Things en Privacidad y seguridad → Automatización."),
    "Não foi possível montar o link do Things.": ("Couldn't create the Things link.", "No se pudo crear el enlace de Things."),
    "Ative o microfone em Ajustes do Sistema → Privacidade e Segurança → Microfone.": ("Enable microphone access in System Settings → Privacy & Security → Microphone.", "Activa el acceso al micrófono en Ajustes del Sistema → Privacidad y seguridad → Micrófono."),
    "A conexão com a OpenAI demorou demais.": ("The connection to OpenAI timed out.", "Se agotó el tiempo de conexión con OpenAI."),
    "A transcrição demorou para terminar.": ("Transcription took too long to finish.", "La transcripción tardó demasiado en terminar."),
    "Não foi possível preparar a transcrição local.": ("Couldn't prepare local transcription.", "No se pudo preparar la transcripción local."),
    "Não foi possível transcrever a gravação no Mac.": ("Couldn't transcribe the recording on this Mac.", "No se pudo transcribir la grabación en este Mac."),
    "Nenhuma ação encontrada.": ("No tasks found.", "No se encontraron tareas."),
    "Abra ou instale o Things 3 neste Mac para adicionar as tarefas.": ("Open or install Things 3 on this Mac to add tasks.", "Abre o instala Things 3 en este Mac para añadir tareas."),
    "1 tarefa adicionada ao Things": ("1 task added to Things", "1 tarea añadida a Things"),
    "%d tarefas adicionadas ao Things": ("%d tasks added to Things", "%d tareas añadidas a Things"),
    "O Things recusou o envio. Confira se as URLs estão ativadas e se o token está correto.": ("Things rejected the request. Check that Things URLs are enabled and the token is correct.", "Things rechazó el envío. Comprueba que las URLs estén activadas y que el token sea correcto."),
    "Envio cancelado no Things.": ("Sending canceled in Things.", "Envío cancelado en Things."),
    "O Things não confirmou o envio. Confira as listas antes de tentar novamente.": ("Things didn't confirm delivery. Check your lists before trying again.", "Things no confirmó el envío. Revisa tus listas antes de volver a intentarlo."),
    "A OpenAI demorou para responder. Tente uma nova captura.": ("OpenAI took too long to respond. Start a new capture.", "OpenAI tardó demasiado en responder. Inicia una nueva captura."),
    "A conexão com a OpenAI falhou. Confira a internet e a chave de API.": ("Couldn't connect to OpenAI. Check your internet connection and API key.", "No se pudo conectar con OpenAI. Comprueba tu conexión a internet y tu clave de API."),
    "Não foi possível concluir a captura. Tente novamente.": ("Couldn't finish capturing. Try again.", "No se pudo completar la captura. Inténtalo de nuevo."),
    "Confirmação simulada": ("Simulated confirmation", "Confirmación simulada"),
    "Não foi possível ler as credenciais salvas nas Chaves do macOS.": ("Couldn't read credentials from macOS Keychain.", "No se pudieron leer las credenciales del llavero de macOS."),
    "Preencha os dois campos ou deixe os dois vazios para apagar as credenciais.": ("Fill in both fields or leave both empty to delete your credentials.", "Completa ambos campos o déjalos vacíos para borrar las credenciales."),
    "Não foi possível acessar as Chaves do macOS (código %d).": ("Couldn't access macOS Keychain (code %d).", "No se pudo acceder al llavero de macOS (código %d)."),
    "Confira a entrada de áudio nos Ajustes do Sistema.": ("Check your audio input in System Settings.", "Comprueba la entrada de audio en Ajustes del Sistema."),
    "A entrada de áudio mudou durante a captura.": ("The audio input changed during capture.", "La entrada de audio cambió durante la captura."),
    "Nenhum microfone disponível. Confira a entrada de áudio do Mac.": ("No microphone available. Check your Mac's audio input.", "No hay micrófono disponible. Comprueba la entrada de audio del Mac."),
    "A transcrição não acompanhou a gravação.": ("Transcription couldn't keep up with the recording.", "La transcripción no pudo seguir el ritmo de la grabación."),
    "Não foi possível preparar o áudio.": ("Couldn't prepare the audio.", "No se pudo preparar el audio."),
    "A OpenAI não conseguiu transcrever a gravação.": ("OpenAI couldn't transcribe the recording.", "OpenAI no pudo transcribir la grabación."),
    "A conexão de áudio foi encerrada.": ("The audio connection closed.", "Se cerró la conexión de audio."),
    "A OpenAI enviou uma resposta de áudio inválida.": ("OpenAI returned an invalid audio response.", "OpenAI devolvió una respuesta de audio no válida."),
    "A OpenAI recusou a sessão de transcrição. Confira o acesso ao modelo gpt-live-transcribe.": ("OpenAI rejected the transcription session. Check access to gpt-live-transcribe.", "OpenAI rechazó la sesión de transcripción. Comprueba el acceso a gpt-live-transcribe."),
    "A OpenAI não retornou uma lista de tarefas completa.": ("OpenAI returned an incomplete task list.", "OpenAI devolvió una lista de tareas incompleta."),
    "Uma das tarefas excedeu o tamanho aceito pelo Things.": ("A task exceeded the size limit in Things.", "Una tarea superó el límite de tamaño de Things."),
    "A OpenAI enviou uma resposta inválida.": ("OpenAI returned an invalid response.", "OpenAI devolvió una respuesta no válida."),
    "A OpenAI recusou o acesso. Confira a chave e as permissões do projeto.": ("OpenAI denied access. Check the API key and project permissions.", "OpenAI denegó el acceso. Comprueba la clave y los permisos del proyecto."),
    "A OpenAI atingiu um limite de uso. Confira o saldo e os limites do projeto.": ("OpenAI reached a usage limit. Check your balance and project limits.", "OpenAI alcanzó un límite de uso. Comprueba el saldo y los límites del proyecto."),
    "A solicitação à OpenAI falhou (HTTP %d).": ("The OpenAI request failed (HTTP %d).", "La solicitud a OpenAI falló (HTTP %d)."),
]
