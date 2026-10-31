//
//  ScreenshotSeedText+Romance.swift
//  Kurn
//
//  Portuguese, Spanish, French and Italian seed text for App Store
//  screenshots. See `ScreenshotSeedText` for the shape every table follows.
//

#if DEBUG
import Foundation

extension ScreenshotSeedText {
    static let portuguese = ScreenshotSeedText(
        language: .portuguese,
        transcriptLanguage: "pt-BR",
        templateName: "Geral",
        productFolder: "Produto",
        roadmapTags: ["Roadmap", "T3"],
        roadmapTitle: "Alinhamento do roadmap",
        roadmapLines: [
            "Vamos começar pelo roadmap do terceiro trimestre. Quero fechar as três prioridades hoje.",
            "Combinado. Nas conversas com clientes, sincronização offline e exportação sempre aparecem.",
            "Eu fico com a exportação — já tenho um rascunho do design da última sprint.",
            "Ótimo. Priya, consegue dimensionar a sincronização offline até sexta?",
            "Sim, vou trabalhar com o time mobile e trago uma estimativa até lá.",
            "Uma dúvida: ainda vamos suportar o formato de importação antigo ou podemos remover?",
            "Vamos remover — o uso está abaixo de um por cento e está atrasando a nova exportação.",
            "Perfeito. Vou registrar isso como decisão na ata."
        ],
        roadmapFollowUp: [
            "Só um complemento — Sam, pode compartilhar os mockups da exportação antes da revisão de quinta?",
            "Sim, coloco na pasta compartilhada hoje à noite."
        ],
        roadmapSections: [
            ScreenshotSeedSection(title: "Decisões", items: [
                "Sincronização offline e exportação são as duas prioridades do trimestre.",
                "Remover o suporte ao formato de importação antigo."
            ]),
            ScreenshotSeedSection(title: "Próximos passos", items: [
                "Sam — finalizar o design da exportação e compartilhar os mockups antes de quinta.",
                "Priya — dimensionar a sincronização offline com o time mobile até sexta."
            ]),
            ScreenshotSeedSection(title: "Pontos em aberto", items: [
                "O formato de importação antigo sai nesta versão ou na próxima?"
            ])
        ],
        roadmapAttachmentName: "Roadmap T3.pdf",
        roadmapAttachmentText: "Roadmap T3: novo onboarding, sincronização offline, página de preços.",
        designFolder: "Design",
        designTag: "Interface",
        designTitle: "Revisão de design",
        designLines: [
            "Me mostra o novo fluxo de exportação — quero ver primeiro o estado vazio.",
            "Claro. Quando ainda não há nada para exportar, mostramos uma explicação curta e um único botão.",
            "Funciona. Dá para o botão usar a mesma cor de destaque do resto do app?",
            "Boa observação — ajusto antes da revisão de quinta."
        ],
        designSections: [
            ScreenshotSeedSection(title: "Feedback", items: [
                "Estado vazio da exportação aprovado como está.",
                "Usar a cor de destaque do app no botão principal, não uma cor avulsa."
            ]),
            ScreenshotSeedSection(title: "Próximos passos", items: [
                "Jordan — ajustar a cor do botão antes da revisão de quinta."
            ])
        ],
        clientsFolder: "Clientes",
        onboardingTags: ["Onboarding", "Prioridade"],
        onboardingTitle: "Onboarding do cliente",
        onboardingLines: [
            "Boas-vindas — vamos ver como sua equipe vai usar o Kurn no dia a dia.",
            "Toda reunião fica no aparelho, a menos que você ative a transcrição na nuvem."
        ],
        onboardingCheckIn: [
            "Só para acompanhar — alguma dúvida depois de testar nesta semana?",
            "Só uma — podemos convidar mais duas pessoas da equipe?"
        ],
        onboardingSections: [
            ScreenshotSeedSection(title: "Resumo", items: [
                "Apresentamos ao cliente a gravação, a transcrição e os resumos no aparelho.",
                "O cliente perguntou sobre incluir mais duas pessoas."
            ]),
            ScreenshotSeedSection(title: "Próximos passos", items: [
                "Enviar ao cliente o convite para duas vagas adicionais."
            ])
        ],
        interviewTitle: "Entrevista com cliente",
        interviewLines: [
            "Conte da última vez que você precisou achar anotações de uma reunião antiga.",
            "Levei vinte minutos para descobrir quem era responsável por uma decisão de dois meses atrás."
        ],
        interviewSummaryTitle: "Resumo",
        interviewSummary: "O cliente tem dificuldade em achar decisões e responsáveis de reuniões passadas; busca e acompanhamento claro de tarefas são os maiores pedidos.",
        standupTitle: "Daily semanal",
        standupLine: "Rodada rápida: o que saiu semana passada e o que está travado?"
    )

    static let spanish = ScreenshotSeedText(
        language: .spanish,
        transcriptLanguage: "es-ES",
        templateName: "General",
        productFolder: "Producto",
        roadmapTags: ["Roadmap", "T3"],
        roadmapTitle: "Revisión del roadmap",
        roadmapLines: [
            "Empecemos por el roadmap del tercer trimestre. Quiero cerrar hoy las tres prioridades.",
            "De acuerdo. En las llamadas con clientes siempre salen la sincronización offline y la exportación.",
            "Yo me encargo de la exportación — ya tengo un borrador del diseño del último sprint.",
            "Genial. Priya, ¿puedes estimar la sincronización offline para el viernes?",
            "Sí, lo veo con el equipo móvil y para entonces tengo una estimación.",
            "Una duda: ¿seguimos soportando el formato de importación antiguo o lo quitamos?",
            "Quitémoslo — lo usa menos del uno por ciento y está retrasando la nueva exportación.",
            "Perfecto. Lo apunto como decisión en el acta."
        ],
        roadmapFollowUp: [
            "Una cosa más — Sam, ¿puedes compartir los mockups de la exportación antes de la revisión del jueves?",
            "Sí, los dejo esta noche en la carpeta compartida."
        ],
        roadmapSections: [
            ScreenshotSeedSection(title: "Decisiones", items: [
                "La sincronización offline y la exportación son las dos prioridades del trimestre.",
                "Retirar el formato de importación antiguo."
            ]),
            ScreenshotSeedSection(title: "Tareas", items: [
                "Sam — terminar el diseño de la exportación y compartir los mockups antes del jueves.",
                "Priya — estimar la sincronización offline con el equipo móvil para el viernes."
            ]),
            ScreenshotSeedSection(title: "Preguntas abiertas", items: [
                "¿Retiramos el formato antiguo en esta versión o en la siguiente?"
            ])
        ],
        roadmapAttachmentName: "Roadmap T3.pdf",
        roadmapAttachmentText: "Roadmap T3: nuevo onboarding, sincronización offline, página de precios.",
        designFolder: "Diseño",
        designTag: "Interfaz",
        designTitle: "Revisión de diseño",
        designLines: [
            "Enséñame el nuevo flujo de exportación — primero quiero ver el estado vacío.",
            "Claro. Cuando aún no hay nada que exportar, mostramos una explicación breve y un solo botón.",
            "Me vale. ¿Puede el botón usar el mismo color de acento que el resto de la app?",
            "Bien visto — lo cambio antes de la revisión del jueves."
        ],
        designSections: [
            ScreenshotSeedSection(title: "Comentarios", items: [
                "El estado vacío de la exportación se aprueba tal cual.",
                "Usar el color de acento de la app en el botón principal, no un color suelto."
            ]),
            ScreenshotSeedSection(title: "Tareas", items: [
                "Jordan — cambiar el color del botón antes de la revisión del jueves."
            ])
        ],
        clientsFolder: "Clientes",
        onboardingTags: ["Onboarding", "Prioridad"],
        onboardingTitle: "Onboarding del cliente",
        onboardingLines: [
            "Bienvenidos — veamos cómo usará tu equipo Kurn en el día a día.",
            "Cada reunión se queda en el dispositivo salvo que actives la transcripción en la nube."
        ],
        onboardingCheckIn: [
            "Un seguimiento rápido — ¿alguna duda tras probarlo esta semana?",
            "Solo una — ¿podemos invitar a dos personas más del equipo?"
        ],
        onboardingSections: [
            ScreenshotSeedSection(title: "Resumen", items: [
                "Mostramos al cliente la grabación, la transcripción y los resúmenes en el dispositivo.",
                "El cliente preguntó por añadir a dos personas más."
            ]),
            ScreenshotSeedSection(title: "Tareas", items: [
                "Enviar al cliente la invitación para dos plazas adicionales."
            ])
        ],
        interviewTitle: "Entrevista con cliente",
        interviewLines: [
            "Cuéntame la última vez que tuviste que buscar notas de una reunión antigua.",
            "Tardé veinte minutos en averiguar quién era responsable de una decisión de hace dos meses."
        ],
        interviewSummaryTitle: "Resumen",
        interviewSummary: "Al cliente le cuesta encontrar decisiones y responsables de reuniones pasadas; la búsqueda y un seguimiento claro de tareas son lo que más pide.",
        standupTitle: "Daily semanal",
        standupLine: "Ronda rápida: ¿qué salió la semana pasada y qué está bloqueado?"
    )

    static let french = ScreenshotSeedText(
        language: .french,
        transcriptLanguage: "fr-FR",
        templateName: "Général",
        productFolder: "Produit",
        roadmapTags: ["Roadmap", "T3"],
        roadmapTitle: "Point roadmap produit",
        roadmapLines: [
            "Commençons par la roadmap du troisième trimestre. Je veux arrêter les trois priorités aujourd'hui.",
            "D'accord. Dans les appels clients, la synchro hors ligne et l'export reviennent sans cesse.",
            "Je prends l'export — j'ai déjà une maquette du dernier sprint.",
            "Parfait. Priya, tu peux chiffrer la synchro hors ligne d'ici vendredi ?",
            "Oui, je vois ça avec l'équipe mobile et j'aurai une estimation d'ici là.",
            "Une question : on garde l'ancien format d'import ou on peut le retirer ?",
            "Retirons-le — moins d'un pour cent l'utilise et il ralentit la refonte de l'export.",
            "Très bien. Je le note comme décision dans le compte rendu."
        ],
        roadmapFollowUp: [
            "Petit suivi — Sam, tu peux partager les maquettes de l'export avant la revue de jeudi ?",
            "Oui, je les dépose ce soir dans le dossier partagé."
        ],
        roadmapSections: [
            ScreenshotSeedSection(title: "Décisions", items: [
                "La synchro hors ligne et l'export sont les deux priorités du trimestre.",
                "Retirer l'ancien format d'import."
            ]),
            ScreenshotSeedSection(title: "Actions", items: [
                "Sam — finaliser le design de l'export et partager les maquettes avant jeudi.",
                "Priya — chiffrer la synchro hors ligne avec l'équipe mobile d'ici vendredi."
            ]),
            ScreenshotSeedSection(title: "Questions ouvertes", items: [
                "Retire-t-on l'ancien format dans cette version ou la suivante ?"
            ])
        ],
        roadmapAttachmentName: "Roadmap T3.pdf",
        roadmapAttachmentText: "Roadmap T3 : nouvel onboarding, synchro hors ligne, page tarifs.",
        designFolder: "Design",
        designTag: "Interface",
        designTitle: "Revue de design",
        designLines: [
            "Montre-moi le nouveau parcours d'export — je veux d'abord voir l'état vide.",
            "Bien sûr. Quand il n'y a encore rien à exporter, on affiche une courte explication et un seul bouton.",
            "Ça me va. Le bouton peut-il reprendre la couleur d'accent du reste de l'app ?",
            "Bien vu — je le modifie avant la revue de jeudi."
        ],
        designSections: [
            ScreenshotSeedSection(title: "Retours", items: [
                "L'état vide de l'export est validé tel quel.",
                "Utiliser la couleur d'accent de l'app pour le bouton principal."
            ]),
            ScreenshotSeedSection(title: "Actions", items: [
                "Jordan — modifier la couleur du bouton avant la revue de jeudi."
            ])
        ],
        clientsFolder: "Clients",
        onboardingTags: ["Onboarding", "Priorité"],
        onboardingTitle: "Onboarding client",
        onboardingLines: [
            "Bienvenue — voyons comment votre équipe va utiliser Kurn au quotidien.",
            "Chaque réunion reste sur l'appareil, sauf si vous activez la transcription cloud."
        ],
        onboardingCheckIn: [
            "Petit point — des questions après l'avoir essayé cette semaine ?",
            "Une seule — peut-on inviter deux personnes de plus de l'équipe ?"
        ],
        onboardingSections: [
            ScreenshotSeedSection(title: "Résumé", items: [
                "Présentation au client de l'enregistrement, de la transcription et des résumés sur l'appareil.",
                "Le client a demandé à ajouter deux personnes."
            ]),
            ScreenshotSeedSection(title: "Actions", items: [
                "Envoyer au client l'invitation pour deux places supplémentaires."
            ])
        ],
        interviewTitle: "Entretien client",
        interviewLines: [
            "Racontez-moi la dernière fois que vous avez dû retrouver les notes d'une ancienne réunion.",
            "J'ai mis vingt minutes à savoir qui portait une décision prise il y a deux mois."
        ],
        interviewSummaryTitle: "Résumé",
        interviewSummary: "Le client peine à retrouver décisions et responsables des réunions passées ; la recherche et un suivi clair des actions sont ses principales demandes.",
        standupTitle: "Point hebdo",
        standupLine: "Tour rapide : qu'est-ce qui est sorti la semaine dernière, qu'est-ce qui bloque ?"
    )

    static let italian = ScreenshotSeedText(
        language: .italian,
        transcriptLanguage: "it-IT",
        templateName: "Generale",
        productFolder: "Prodotto",
        roadmapTags: ["Roadmap", "Q3"],
        roadmapTitle: "Allineamento roadmap",
        roadmapLines: [
            "Partiamo dalla roadmap del terzo trimestre. Oggi voglio fissare le tre priorità.",
            "D'accordo. Nelle chiamate con i clienti tornano sempre la sincronizzazione offline e l'esportazione.",
            "Mi occupo io dell'esportazione — ho già una bozza del design dall'ultimo sprint.",
            "Ottimo. Priya, riesci a stimare la sincronizzazione offline entro venerdì?",
            "Sì, ne parlo con il team mobile e per allora ho una stima.",
            "Una domanda: supportiamo ancora il vecchio formato di importazione o lo togliamo?",
            "Togliamolo — lo usa meno dell'uno per cento e rallenta la nuova esportazione.",
            "Perfetto. Lo segno come decisione nel verbale."
        ],
        roadmapFollowUp: [
            "Un'aggiunta — Sam, puoi condividere i mockup dell'esportazione prima della revisione di giovedì?",
            "Sì, li metto stasera nella cartella condivisa."
        ],
        roadmapSections: [
            ScreenshotSeedSection(title: "Decisioni", items: [
                "Sincronizzazione offline ed esportazione sono le due priorità del trimestre.",
                "Rimuovere il vecchio formato di importazione."
            ]),
            ScreenshotSeedSection(title: "Azioni", items: [
                "Sam — completare il design dell'esportazione e condividere i mockup entro giovedì.",
                "Priya — stimare la sincronizzazione offline con il team mobile entro venerdì."
            ]),
            ScreenshotSeedSection(title: "Domande aperte", items: [
                "Rimuoviamo il vecchio formato in questa versione o nella prossima?"
            ])
        ],
        roadmapAttachmentName: "Roadmap Q3.pdf",
        roadmapAttachmentText: "Roadmap Q3: nuovo onboarding, sincronizzazione offline, pagina prezzi.",
        designFolder: "Design",
        designTag: "Interfaccia",
        designTitle: "Revisione design",
        designLines: [
            "Mostrami il nuovo flusso di esportazione — prima voglio vedere lo stato vuoto.",
            "Certo. Quando non c'è ancora niente da esportare, mostriamo una breve spiegazione e un solo pulsante.",
            "Va bene. Il pulsante può usare lo stesso colore di accento del resto dell'app?",
            "Giusto — lo sistemo prima della revisione di giovedì."
        ],
        designSections: [
            ScreenshotSeedSection(title: "Feedback", items: [
                "Lo stato vuoto dell'esportazione è approvato così.",
                "Usare il colore di accento dell'app per il pulsante principale."
            ]),
            ScreenshotSeedSection(title: "Azioni", items: [
                "Jordan — cambiare il colore del pulsante prima della revisione di giovedì."
            ])
        ],
        clientsFolder: "Clienti",
        onboardingTags: ["Onboarding", "Priorità"],
        onboardingTitle: "Onboarding cliente",
        onboardingLines: [
            "Benvenuti — vediamo come il vostro team userà Kurn ogni giorno.",
            "Ogni riunione resta sul dispositivo, a meno che non attiviate la trascrizione cloud."
        ],
        onboardingCheckIn: [
            "Un rapido aggiornamento — domande dopo averlo provato questa settimana?",
            "Solo una — possiamo invitare altre due persone del team?"
        ],
        onboardingSections: [
            ScreenshotSeedSection(title: "Riepilogo", items: [
                "Mostrati al cliente registrazione, trascrizione e riassunti sul dispositivo.",
                "Il cliente ha chiesto di aggiungere altre due persone."
            ]),
            ScreenshotSeedSection(title: "Azioni", items: [
                "Inviare al cliente l'invito per due posti aggiuntivi."
            ])
        ],
        interviewTitle: "Intervista cliente",
        interviewLines: [
            "Mi racconti l'ultima volta che ha dovuto ritrovare gli appunti di una vecchia riunione.",
            "Ci ho messo venti minuti a capire chi era responsabile di una decisione di due mesi fa."
        ],
        interviewSummaryTitle: "Riepilogo",
        interviewSummary: "Il cliente fatica a ritrovare decisioni e responsabili delle riunioni passate; ricerca e un chiaro monitoraggio delle azioni sono le richieste principali.",
        standupTitle: "Stand-up settimanale",
        standupLine: "Giro veloce: cosa è uscito la settimana scorsa, cosa è bloccato?"
    )
}
#endif
