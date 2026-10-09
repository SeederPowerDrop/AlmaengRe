<!-- almeng-guide-source-sha256: 3466de06f2ee465a229033f6d1ea1bbff10289b647c5d5babc03a109120e60c4 -->

<a name="top"></a>

# Guide d’utilisation d’알맹Re

[한국어](ko.md) · [English](en.md) · [日本語](ja.md) · [简体中文](zh-Hans.md) · [Français](fr.md) · [Español](es.md) · [Tiếng Việt](vi.md)

[← 알맹Re](../../README.md) · [PDF](pdf/AlmaengRe-User-Guide-fr.pdf)

**Ouvrir, parcourir, comparer, étiqueter et retoucher vos images sur Mac**

Un guide pratique de la version de développement 0.13.1 actuelle. Commencez par ouvrir un dossier d’images, puis consultez le chapitre correspondant à votre tâche. Les noms de menus de ce guide reprennent ceux de l’interface française.

Version 0.13.1 · Au 2026-10-09

> Les captures montrent l’application réelle avec une interface coréenne et des images de démonstration synthétiques. Les annotations numérotées et les explications sont traduites en français ; les pixels des captures restent inchangés. Aucune collection de photos personnelle n’est utilisée.

## Sommaire

- [1. Ouvrir des images, des dossiers et des archives ZIP](#open)
- [2. Parcourir les images et se concentrer sur une photo](#viewer)
- [3. Rechercher et sélectionner dans Tout voir](#overview)
- [4. Comparer deux collections d’images](#compare)
- [5. Étiqueter les photos et vidéos](#tags)
- [6. Définir les noms, couleurs et règles de suivi des étiquettes](#tag-editor)
- [7. Retrouver les photos par lieu](#map)
- [8. Examiner les informations et les métadonnées](#information)
- [9. Retoucher une image et exporter une copie](#editing)
- [10. Renommer, redimensionner, convertir et partager en lot](#batch)
- [11. Ajouter un filigrane : texte, EXIF et logo](#watermark)
- [12. Vidéos : lecture, images et extraits](#video)
- [13. Parcourir et enregistrer les images d’une animation](#animation)
- [14. Zoomer et comparer le résultat de l’agrandissement IA](#ai-upscaling)
- [15. Comprendre la qualité d’affichage, le HDR et le chargement](#quality)
- [16. Lire un album photo ou définir le fond d’écran](#slideshow)
- [17. Adapter l’application à vos habitudes](#settings)
- [18. Raccourcis et dépannage rapide](#shortcuts)
- [Les raccourcis en un regard](#shortcut-reference)

---

<a name="open"></a>

## 1. Ouvrir des images, des dossiers et des archives ZIP

Ouvrez photos, vidéos, dossiers et ZIP avec Ouvrir…. Photos et vidéos compatibles s’affichent ensemble par défaut ; les ZIP sont limités aux images.

![L’accueil réunit le logo, le bouton d’ouverture et les photos récemment consultées.](figures/home.png)

**Écran 01.** L’accueil réunit le logo, le bouton d’ouverture et les photos récemment consultées.

1. **Ouvrir ou reprendre** — Ouvrir… charge une nouvelle collection ; Reprendre la session précédente retrouve votre travail enregistré.
2. **Sept photos récentes** — Jusqu’à sept photos vues dans la Visionneuse ou Comparaison d’images, les plus récentes d’abord. Cliquez pour rouvrir. Images, GIF et photos dans les ZIP inclus ; vidéos exclues.
3. **Effacer l’historique récent** — Retirer de la liste pour une photo ou Vider la liste efface uniquement l’historique, jamais les originaux. Consulter à nouveau une photo peut la remettre dans la liste.

### Marche à suivre

1. Lancez 알맹Re sous macOS 14 ou ultérieur pour afficher l’accueil. Utilisez Ouvrir… (⌘O) ou cliquez sur une photo récente. Ouvrir… figure aussi dans la barre d’outils et le menu Fichier.
2. Choisissez un dossier pour le parcourir. Une photo ouvre son dossier à partir de cette image ; une sélection multiple ouvre ces fichiers seuls. Afficher les vidéos est activé par défaut et mémorisé. Ouvrir une vidéo l’active aussi.
3. Choisissez une archive ZIP pour afficher ses images prises en charge, y compris celles de ses sous-dossiers. Vous pouvez aussi ouvrir des fichiers depuis le Finder ou déposer des images et des dossiers dans l’application.

### Dossiers et favoris

L’arborescence des dossiers se développe selon vos besoins. Cliquez sur un nom de dossier pour l’ouvrir, utilisez la flèche vers le haut pour remonter et actualisez après des changements dans le Finder. Épinglez un dossier au-dessus de l’arborescence pour y accéder rapidement. Ouvrir un dossier ordinaire n’inclut pas automatiquement tous ses sous-dossiers.

### ZIP en lecture seule

Les images sont extraites dans un dossier temporaire tant que l’archive est ouverte. Exportez une copie avant de renommer un fichier ou de modifier ses métadonnées source. L’application ne réécrit pas le ZIP. Les archives sans compression ou utilisant Deflate sont prises en charge ; les archives chiffrées et les autres méthodes de compression sont refusées. Les limites sont de 2 Gio par archive, 10 000 entrées, 256 Mio par entrée extraite et 1 Gio de données extraites au total. Les vidéos contenues dans les ZIP ne sont pas prises en charge.

### Accueil et session précédente

Un lancement normal affiche l’accueil. Reprendre la session précédente restaure si possible la collection, la sélection, la vue et la recherche. Accueil dans la barre d’outils ou le menu conserve le travail en cours. Un fichier ouvert depuis le Finder s’affiche directement. Si les connexions ou autorisations changent, utilisez Ouvrir…. Les retouches et résultats IA non enregistrés ne sont pas restaurés au redémarrage.

### Bon à savoir

- La sélection simultanée de dossiers et d’images individuelles les rassemble sans doublons. En Comparaison d’images, Ouvrir… remplace le contenu du volet A ou B actif et déverrouillé. Aide → Utilisation de base ouvre un bref mode d’emploi dans l’application. Aide → Guide détaillé (GitHub) ouvre le guide complet dans votre langue sur GitHub, dans votre navigateur par défaut.

[Retour en haut](#top)

---

<a name="viewer"></a>

## 2. Parcourir les images et se concentrer sur une photo

La Visionneuse affiche de une à dix images à la fois. Agrandissez les détails ou masquez les commandes environnantes pour vous concentrer sur la photo. En vue multiple, les vidéos affichent une image fixe et se lisent sans son au survol.

![La Visionneuse réunit plusieurs photos et vidéos. Survolez une vidéo pour un aperçu sans son.](figures/viewer.png)

**Écran 02.** La Visionneuse réunit plusieurs photos et vidéos. Survolez une vidéo pour un aperçu sans son.

1. **Modes d’affichage** — Passez entre Visionneuse, Tout voir, Vue carte et Comparaison d’images.
2. **Recherche, filtres et vidéos** — Réglez recherche, format, étiquettes, tri et Afficher les vidéos pour la liste actuelle.
3. **Commandes d’affichage** — Parcourez les éléments et changez leur nombre affiché. Réglez le zoom et le déplacement des photos.

### Marche à suivre

1. Choisissez Visionneuse en haut. Utilisez ← et → pour naviguer. Réglez le nombre d’images par vue avec la commande correspondante ou \[ et \] ; la grille s’adapte à la forme de la fenêtre.
2. Pincez le trackpad ou utilisez = et − pour zoomer. Appuyez sur 0 pour Adapter à la fenêtre et sur 1 pour Taille réelle. Choisissez une commande de déplacement dans les commandes inférieures ou dans Réglages → Général.
3. Appuyez sur F, double-cliquez sur une photo ou touchez brièvement Espace pour activer ou quitter le mode concentration. Appuyez sur Esc pour revenir. Plein écran est une commande distincte : ⌃⌘F.

### Parcourir plusieurs images

Dans la Visionneuse, ←/→ avance d’une page, ou d’un élément avec Marquage ON. Avec plusieurs éléments, ↑/↓ sélectionne la ligne au-dessus ou en dessous dans la page actuelle, sans dépasser la première ni la dernière ligne. Une dernière ligne incomplète sélectionne la carte disponible la plus proche. ⌥←/⌥→ change toujours de page, même pendant le marquage.

### Commandes de déplacement

Choisissez le glissement avec le bouton gauche, Espace + bouton gauche, le bouton droit, le bouton central ou le déplacement à deux doigts. Les raccourcis ⌃⌥1–5 sélectionnent une méthode ; ils ne déplacent pas la photo eux-mêmes. Les balayages horizontaux changent d’image lorsque le geste n’est pas utilisé pour déplacer la photo. Le déplacement ne laisse qu’une petite marge aux bords, même pendant un glissement, pour éviter de perdre la photo dans un grand espace vide. Tout axe plus petit que le volet reste centré ; changer le zoom ou la taille de la fenêtre réajuste les limites. Ces règles s’appliquent aussi à l’affichage de plusieurs images et à la comparaison de qualité du zoom.

### Commandes du mode concentration

Le × inférieur masque uniquement la barre de commandes flottante. Rouvrez-la avec le bouton à côté du nom de fichier. Le × supérieur quitte le mode concentration. Ces boutons restent disponibles même lorsque les noms de fichiers sont masqués. Une brève pression sur Espace ne change pas le mode pendant la saisie ou si cette touche possède un raccourci personnalisé.

### Bon à savoir

- Les vignettes peuvent apparaître à gauche, à droite, en haut ou en bas, ou être masquées. Esc ferme d’abord le mode d’affichage temporaire actif, puis permet de revenir de la Visionneuse à Tout voir.

[Retour en haut](#top)

---

<a name="overview"></a>

## 3. Rechercher et sélectionner dans Tout voir

Tout voir réunit la collection en grille pour sélectionner et préparer les opérations par lot. Les vidéos ont un aperçu fixe.

![Tout voir réunit la grille de vignettes, la recherche et les commandes de sélection et de taille.](figures/overview.png)

**Écran 03.** Tout voir réunit la grille de vignettes, la recherche et les commandes de sélection et de taille.

1. **Grille de vignettes** — Cliquez, sélectionnez une plage ou faites glisser pour choisir les cartes. Les vidéos ont un aperçu fixe ; un double-clic les ouvre en plein écran.
2. **Recherche, filtres et vidéos** — Réglez recherche, tri, format, étiquettes et Afficher les vidéos pour la liste actuelle.
3. **Taille et sélection** — Réglez la taille des aperçus et utilisez les actions sur les images sélectionnées pour les opérations par lot.

### Marche à suivre

1. Dans Tout voir (G), ajustez la taille des vignettes. Un double-clic ouvre une photo dans la Visionneuse ou une vidéo en plein écran.
2. Saisissez du texte dans Rechercher un nom de fichier. La recherche ignore les majuscules ; chaque terme séparé par une espace doit apparaître dans le nom. Choisissez un ou plusieurs formats, ou Tous les formats pour effacer ce filtre.
3. Cliquez pour sélectionner, ⌘ + clic pour ajouter ou retirer, ⇧ + clic pour une plage. Tracez un rectangle depuis une carte ou le fond pour sélectionner les cartes touchées. Avec Marquage ON ou OFF, ←/→ avance d’une carte et ↑/↓ d’une ligne. Le déplacement s’arrête aux première et dernière lignes ; si la dernière est incomplète, la carte disponible la plus proche est choisie. Cela vaut aussi pour les listes filtrées par la carte. Sur OFF, les raccourcis personnalisés sont prioritaires.

### Raccourcis de sélection

Maintenez Maj au début du tracé d’un rectangle pour ajouter à la sélection. Maintenez ⌘ pour inverser la sélection des images dans le rectangle. Esc restaure la sélection précédant ce glissement. ⌘A sélectionne toutes les images de la liste actuellement visible.

### Trier la liste actuelle

Les groupes Nom et fichier, Dimensions et prise de vue, Appareil et couleur et Position réunissent nom, dates de fichier, poids, GPS, largeur, hauteur, date de prise de vue, type, vitesse d’obturation, fabricant, modèle, ouverture et espace colorimétrique. Les noms suivent l’ordre naturel des nombres, la vitesse compare la durée d’exposition et l’ouverture le nombre f. Les valeurs absentes restent à la fin dans les deux sens. Le type suit l’extension, en regroupant les variantes JPEG/TIFF. Les fichiers restent intacts.

### Numéros et taille des aperçus

La commande # affiche ou masque les numéros des vignettes. Les grands numéros sont déplacés hors des petites photos pour préserver leur visibilité. La taille des vignettes est mémorisée ; sa plage est de 44,8 à 665,6 points, chaque cellule restant limitée par la largeur de la fenêtre.

### Limites du tri par informations de prise de vue

Largeur et hauteur décrivent les pixels originaux, orientation du fichier comprise, avant retouches. La date vient des données EXIF ou de la vidéo, jamais de la création du fichier. Sans fuseau horaire, l’heure EXIF est interprétée en UTC pour le tri. Les vidéos utilisent les dimensions, dates, fabricant, modèle et couleurs disponibles ; vitesse et ouverture restent inconnues. Ces données sont lues seulement pour les tris concernés, puis réutilisées : le premier tri peut prendre du temps.

### Bon à savoir

- Recherche par nom, sans contenu ni OCR. Aucun résultat : commandes en haut, Réinitialiser la recherche et les filtres ; fichiers préservés. Photos sans étiquette désactivé, aucune étiquette choisie : aucun filtre d’étiquette.

[Retour en haut](#top)

---

<a name="compare"></a>

## 4. Comparer deux collections d’images

La Comparaison d’images conserve deux collections indépendantes, A et B, côte à côte ou l’une au-dessus de l’autre. Elle permet de comparer des versions ou de vérifier deux dossiers.

![Deux collections dans la Comparaison d’images.](figures/compare.png)

**Écran 04.** Deux collections dans la Comparaison d’images.

1. **Volets A et B** — Sous chaque nom, vérifiez les touches d’étiquettes sélectionnées, les critères et le nombre de photos. Si Photos sans étiquette est désactivé et qu’aucune étiquette n’est sélectionnée, toutes les photos s’affichent ; A/B peuvent se recouper. Si le résultat est vide, vérifiez les étiquettes et les filtres communs de recherche, format et carte. Effacer retire uniquement le filtre d’étiquettes de ce volet.
2. **Comportement de la comparaison** — Choisissez la méthode d’association, la cible de navigation, la répétition du côté le plus court et la liaison du zoom.
3. **Verrous et vignettes** — Figez un côté ou choisissez une autre image dans sa bande de vignettes.

### Marche à suivre

1. Comparer les photos actuelles par étiquette ouvre la liste source dans A/B en gardant recherche, format et zone cartographique. Seul A reprend le filtre d’étiquettes habituel ; B commence avec toutes les photos. Pour d’autres dossiers, utilisez Comparaison d’images (⌃⌥C), Choisir les dossiers à comparer… ou Ouvrir… dans chaque volet.
2. Le bouton d’étiquettes sous le nom de chaque volet permet de sélectionner plusieurs des 12 étiquettes, par exemple 1·F pour A et 3·Q·S pour B. Au moins une étiquette choisie (OR) est le réglage initial ; Toutes les étiquettes choisies (AND) et Photos sans étiquette sont aussi proposés.
3. Sous Navigation des images, choisissez un côté par son nom affiché ou Les deux. Avancez avec les flèches communes ou les vignettes. Activez Lier zoom et déplacement pour examiner les mêmes positions relatives. Chaque volet limite aussi le déplacement à une petite marge aux bords, centre les axes plus petits que le volet et réajuste les limites si le zoom ou la taille de la fenêtre change.

### Navigation et répétition

Parcourez les résultats filtrés dans Ordre de la liste ou associez-les avec Noms identiques : 001.jpg correspond à 001.png ; une image absente laisse un côté vide. Choisir un seul côté passe à Ordre de la liste ; Noms identiques parcourt les paires. Avec Les deux, Boucler le côté le plus court recommence la liste courte ; sinon, elle garde sa dernière image. La répétition utilise Ordre de la liste.

### Verrouillage

Le verrou fixe l’image, le zoom et la position du volet et interdit de changer son filtre d’étiquettes. Verrouillez B pour parcourir A, ou A pour parcourir B. Déverrouiller les deux rétablit Les deux ; verrouiller les deux arrête la navigation. Les vignettes verrouillées restent consultables et défilables.

### Originaux et état mémorisé

La comparaison affiche les originaux sans retouches et exclut les vidéos. Quittez-la pour retoucher, traiter par lot ou choisir un fond d’écran ; Esc revient à la vue précédente. Disposition, liaison, navigation, entrées/positions A/B et filtres d’étiquettes sont restaurés. Les filtres restent lors de nouvelles entrées. Noms de comparaison… définit des alias de 80 caractères maximum. Un champ vide ou Noms automatiques utilise le nom du dossier/ZIP ; Enregistrer applique, Annuler conserve. Un même dossier/ZIP ou une liste mixte utilise A/B ; des dossiers homonymes distincts ajoutent (A)/(B). Sans renommer les dossiers, les alias persistent au redémarrage et à la réouverture ; seules de nouvelles entrées dans le volet les réinitialisent. Survolez un nom abrégé pour le lire.

### Bon à savoir

- ⌥←/⌥→ parcourt A uniquement ; ⇧⌥←/⇧⌥→ parcourt B uniquement. Noms identiques ignore l’extension, les majuscules et les écritures Unicode équivalentes.

[Retour en haut](#top)

---

<a name="tags"></a>

## 5. Étiqueter les photos et vidéos

Ajoutez plusieurs étiquettes aux photos et vidéos pendant la navigation. Seul Marquage ON permet de les modifier ; ce sont des marques, pas des actions sur les originaux.

![Marquage ON : touches et boutons inférieurs pour l’élément actuel, menu propre à chaque vignette.](figures/tags.png)

**Écran 05.** Marquage ON : touches et boutons inférieurs pour l’élément actuel, menu propre à chaque vignette.

1. **Marquage ON/OFF** — ON permet de modifier les étiquettes ; OFF rétablit les raccourcis ordinaires.
2. **Touches et boutons inférieurs** — Modifiez les étiquettes de l’élément actuel. Plusieurs peuvent coexister.
3. **Menu de chaque vignette** — Modifiez seulement cette photo ou vidéo, sans changer la sélection actuelle ou multiple.

### Marche à suivre

1. Utilisez Marquage ON/OFF, Étiquettes des photos ou ⌘⇧M. ON termine la saisie de recherche. Les touches visent l’élément actuel, ou la photo du volet actif en Comparaison d’images.
2. Sur ON, utilisez les touches physiques 1–4, QWER, ASDF ou les boutons inférieurs. Dans Visionneuse et Tout voir, le menu de chaque vignette ne modifie que sa photo ou vidéo, sans changer la sélection ni traiter toute une sélection multiple.
3. En vue ordinaire, passez sur OFF avec ⌘⇧M, Esc ou la fermeture du panneau. Le filtre Étiquettes propose Au moins une étiquette choisie, Toutes les étiquettes choisies ou Photos sans étiquette. En comparaison, réglez chaque filtre sous le nom du volet.

### Garder un rythme régulier

Aucune avance automatique après marquage. Sur ON, la liste reste stable et ←/→ dans la Visionneuse avance d’un élément. OFF actualise les résultats. La comparaison diffère aussi l’actualisation, sauf changement explicite du filtre. Dans Visionneuse, le marquage attend l’affichage de la photo ou de l’aperçu vidéo demandé.

### Signification des touches

Noms initiaux : 1–4 Une étoile, Deux étoiles, Trois étoiles, Quatre étoiles ; Q Téléverser, W Retoucher, E Supprimer, R En attente ; A Paysage, S Personnes, D Objets, F Animaux. Ces étiquettes sont modifiables : les touches ne téléversent, ne retouchent, ne suppriment ni ne déplacent les fichiers. Les noms déjà enregistrés sont conservés.

### Enregistrement local

Les étiquettes attribuées, leurs noms et couleurs ainsi que les rapports sont conservés dans la base SQLite locale ~/Library/Application Support/org.openimageviewer.ImageViewer/PhotoMarks.sqlite. Ils reviennent au prochain lancement, restent distincts des métadonnées EXIF et ne sont synchronisés ni par XMP ni par une photothèque dans le cloud.

### Bon à savoir

- Sur OFF, 1 et F retrouvent Taille réelle et le mode concentration. En vidéo plein écran, le bouton de marquage, le menu et les touches concernent cette vidéo ; ←/→ règlent toujours la lecture et Esc ferme d’abord le plein écran.

[Retour en haut](#top)

---

<a name="tag-editor"></a>

## 6. Définir les noms, couleurs et règles de suivi des étiquettes

Donnez aux douze touches des noms adaptés à votre travail. Les affectations sont communes aux dossiers ; le suivi et ses rapports conservent les étiquettes lors des changements de fichiers reconnus.

![L’éditeur commun des noms et couleurs d’étiquettes.](figures/tag-editor.png)

**Écran 06.** L’éditeur commun des noms et couleurs d’étiquettes.

1. **Noms par touche** — Chaque touche fixe reçoit un nom modifiable, commun à tous les dossiers.
2. **Couleurs** — Choisissez un repère visuel cohérent dans la palette de dix couleurs.
3. **Aperçu et enregistrement** — Vérifiez les affectations, puis enregistrez les changements pour les conserver à la prochaine session.

### Marche à suivre

1. Ouvrez Réglages → Étiquettes photo, ou choisissez Étiquettes des photos → Modifier les noms et couleurs…. Vous pouvez modifier les affectations avant d’ouvrir des photos.
2. Saisissez un nom pour chaque touche et choisissez l’une des dix couleurs. L’aperçu Étiquettes des touches reflète la saisie.
3. Cliquez sur Enregistrer pour appliquer les noms et couleurs partout. Annuler les modifications dans les réglages rétablit les dernières affectations enregistrées ; Annuler ferme l’éditeur séparé sans enregistrer.

### Des repères visuels cohérents

Les couleurs apparaissent dans le panneau d’étiquettes, les menus, les filtres et les badges des vignettes. Une coche et un fond de sélection indiquent aussi l’attribution : la couleur n’est donc pas le seul repère. Changer un nom ou une couleur n’efface pas les étiquettes déjà attribuées.

### Renommage et déplacement

L’application mémorise les signets macOS et l’identité des fichiers étiquetés. Un renommage dans l’application conserve les étiquettes. Les changements du Finder sur le même volume peuvent être retrouvés au lancement, à l’ouverture du dossier ou au contrôle du rapport. Ce contrôle ne recharge pas la liste des photos : rouvrez ou actualisez le dossier concerné. Les images ZIP sont identifiées par leur archive et leur chemin interne.

### Limites du suivi

Les copies sont des photos distinctes ; un nouveau fichier à une ancienne adresse n’hérite pas des étiquettes. Un autre volume, un remplacement, un signet indisponible ou des autorisations modifiées peuvent empêcher la reconnexion. Indisponible ne signifie pas supprimé : le disque peut être déconnecté. Les anciennes étiquettes fondées sur les chemins nécessitent une ouverture à l’emplacement d’origine avant déplacement.

### Bon à savoir

- Ouvrez Étiquettes des photos → Rapport des fichiers classés… : les événements Indisponible, Nom ou emplacement modifié et Retrouvé gardent leur date, leurs étiquettes et leurs chemins après redémarrage. Le contrôle se fait au lancement, à l’ouverture du rapport et avec Vérifier à nouveau. L’application ne recherche pas sur tout le disque et n’analyse pas le contenu. Sauvegardez originaux et données locales avec vos sauvegardes Mac habituelles.

[Retour en haut](#top)

---

<a name="map"></a>

## 7. Retrouver les photos par lieu

Vue carte place sur une carte les photos contenant des métadonnées GPS. Combinez jusqu’à trois zones pour parcourir ensemble des images de plusieurs lieux.

![Vue carte avec ses zones de sélection et le résumé des photos correspondantes.](figures/map.png)

**Écran 07.** Vue carte avec ses zones de sélection et le résumé des photos correspondantes.

1. **Outils de zone** — Ajoutez un rayon, un rectangle, un contour à main levée ou l’étendue actuelle de la carte.
2. **Poignées des zones** — Déplacez et redimensionnez la zone active ; combinez au maximum trois zones.
3. **Parcourir les résultats** — Ouvrez les photos correspondantes dans la Visionneuse ou Tout voir en conservant le filtre géographique.

### Marche à suivre

1. Ouvrez une collection et choisissez Vue carte. Les photos proches sont regroupées en vignettes superposées avec leur nombre. Cliquez sur un lieu pour prévisualiser ses images, puis utilisez Voir la photo pour en ouvrir une.
2. Choisissez Rayon ou Rectangle pour ajouter une zone au centre actuel de la carte. Déplacez sa poignée numérotée pour la repositionner et sa petite poignée de taille pour la redimensionner. Le rayon peut aussi être saisi en kilomètres.
3. Choisissez Zone à main levée et tracez un contour, ou ajoutez Zone de carte actuelle. Combinez jusqu’à trois zones, puis ouvrez la Visionneuse ou Tout voir. Photos de la zone permet de renommer, convertir, redimensionner ou partager directement les fichiers correspondants.

### Combiner et modifier les zones

Une photo située dans au moins une zone sélectionnée est incluse une seule fois, même si les zones se chevauchent. Choisissez Zone 1, 2 ou 3 pour la modifier, utilisez son × pour la supprimer ou effacez toutes les zones. Esc annule un tracé à main levée ou rétablit l’état précédant un déplacement ou un redimensionnement en cours.

### Conserver la sélection

Un bandeau bleu « Photos sélectionnées sur la carte uniquement » au-dessus de la Visionneuse et de Tout voir indique le nombre de zones et de photos affichées. Il reste visible en mode concentration et si le résultat est vide. Ouvrir la sélection dans la Visionneuse ou Tout voir conserve la restriction géographique et les filtres de nom, format et étiquettes. Dans l’aperçu d’un lieu, Cette photo traite l’image courante et Toutes les photos de ce lieu traite le groupe. Effacer la zone de carte retrouve la liste sans restriction géographique, y compris les photos sans GPS ; ouvrir une photo hors zone supprime cette restriction.

### Chargement et état mémorisé

Après un changement de mode, Retour à la carte ou Vue carte retrouve la dernière position et le zoom. Au redémarrage, la carte cadre les zones restaurées sans retrouver la position exacte. Ouvrir un nouveau dossier réinitialise les zones et la position. Le fond de carte nécessite Internet. Les photos sans GPS sont absentes ; la lecture des lieux peut prendre du temps dans une grande collection.

### Bon à savoir

- Si aucune photo ne correspond, agrandissez ou déplacez la zone et vérifiez les autres filtres. Les boutons d’ouverture sont indisponibles pendant le calcul ou lorsque la sélection est vide.

[Retour en haut](#top)

---

<a name="information"></a>

## 8. Examiner les informations et les métadonnées

Le bouton i circulaire reste Informations sur l’image. Il décrit la photo actuelle ; l’histoire de l’application se trouve dans Aide → À propos.

### Marche à suivre

1. Sélectionnez une photo et cliquez sur le bouton i circulaire, ou utilisez Navigation → Panneau d’informations.
2. Examinez la taille du fichier, les dimensions, les informations colorimétriques et les données appareil photo/EXIF disponibles. En présence de GPS, le panneau affiche un plan Apple ; Google Maps ouvre les mêmes coordonnées à l’extérieur de l’application.
3. Pour modifier les champs de fichier ou intégrés pris en charge, ouvrez Modifier les informations de l’image, corrigez les valeurs et vérifiez-les avant Enregistrer.

### Enregistrer des métadonnées modifie le fichier

Contrairement aux retouches visuelles, les métadonnées modifiées sont écrites dans le fichier source. Les champs comprennent le nom, la date de modification, la description, les droits, les DPI, les informations d’appareil photo et le GPS, selon le format. L’éditeur prépare un fichier temporaire avant de remplacer le fichier source. Les champs intégrés non pris en charge sont désactivés ; les images ZIP sont en lecture seule.

### Supprimer ou corriger une valeur

Vider un champ de texte modifiable supprime la métadonnée à l’enregistrement. Désactiver le GPS supprime les balises de position EXIF/XMP standard. Les coordonnées exigent latitude et longitude. Modifier l’extension ne convertit pas l’image ; utilisez Exporter ou Convertir, redimensionner et compresser.

### Bien lire l’histogramme

Les histogrammes RGB et de luminance décrivent un aperçu SDR pondéré par la transparence et suivent les retouches. Les pourcentages de noir et de blanc comptent les pixels de l’aperçu dont tous les canaux RGB valent 0 ou 255. Ce n’est ni un histogramme du capteur RAW ni une mesure de la luminosité HDR de l’original.

### Bon à savoir

- Conservez une copie avant de modifier des métadonnées que vous pourriez vouloir rétablir. L’icône i concerne la photo ; Aide → À propos ouvre la présentation de l’application et les licences.

[Retour en haut](#top)

---

<a name="editing"></a>

## 9. Retoucher une image et exporter une copie

Retouche d’image prévisualise les modifications sans écraser l’original. Exportez le résultat avant de quitter : les retouches ne sont conservées que pendant la session actuelle.

![Le panneau de retouche à côté de l’aperçu de l’image actuelle.](figures/editing.png)

**Écran 08.** Le panneau de retouche à côté de l’aperçu de l’image actuelle.

1. **Présence et rendus argentiques** — Ouvrez Présence pour régler l’image ou choisissez un rendu argentique et son intensité.
2. **Aperçu de l’image** — Examinez le résultat actuel ; utilisez Taille réelle pour les réglages de détail.
3. **Copies et filigranes** — Choisissez format et qualité pour exporter une copie. Ajouter un filigrane… vise uniquement la photo actuelle.

### Marche à suivre

1. Sélectionnez une photo et cliquez sur le bouton Retouche d’image en forme de curseurs. Depuis Tout voir, cette action ouvre la photo dans la Visionneuse.
2. Recadrez en traçant un rectangle sur l’image. Déplacez-le depuis l’intérieur, redimensionnez ses coins ou saisissez un rapport et des dimensions. Appliquez le recadrage ; annuler sa fenêtre conserve les retouches précédentes. Tournez par pas de 90° ou utilisez Miroir horizontal / Miroir vertical.
3. Réglez la lumière, les couleurs et les détails. Choisissez un format de sortie disponible et la qualité dans le panneau de retouche, puis cliquez sur Exporter… ou appuyez sur ⌘E pour créer un nouveau fichier.

### Réglages

Utilisez exposition, luminosité, contraste, hautes lumières, ombres, point noir et blancs pour les tons ; teinte, température, vibrance et saturation pour les couleurs. Les courbes offrent cinq points pour RGB ou chaque canal. Le mélangeur à huit couleurs règle la teinte, la saturation et la luminosité de chaque couleur. Texture, clarté, correction du voile et rendus argentiques complètent ces réglages.

### Réinitialiser et vérifier

Réinitialiser supprime toutes les retouches visuelles de la photo actuelle. Supprimer le recadrage conserve les autres réglages. Cliquez à nouveau sur le même bouton de retournement pour l’annuler. Vérifiez la netteté et la réduction du bruit en Taille réelle et dans le fichier exporté.

### Enregistrer avant de quitter

Chaque photo conserve ses retouches tant que l’application reste ouverte. Le lancement suivant ne les restaure pas. L’exportation propose un nom se terminant par -edited et interdit d’écraser la source. Les formats disponibles dépendent des encodeurs fournis par macOS.

### Bon à savoir

- La Comparaison d’images affiche les originaux, sans ces retouches. L’Agrandissement IA utilise lui aussi l’image source sans les réglages de la visionneuse ; exportez d’abord une copie retouchée pour agrandir ce résultat.

[Retour en haut](#top)

---

<a name="batch"></a>

## 10. Renommer, redimensionner, convertir et partager en lot

Utilisez les fichiers sélectionnés dans la Visionneuse, Tout voir, les résultats filtrés par étiquette ou la carte. Le renommage modifie les noms source ; la conversion crée des copies et Partager les fichiers… ouvre le partage macOS.

![La fenêtre de conversion par lot, ses réglages de taille et la prévisualisation des fichiers.](figures/batch.png)

**Écran 09.** La fenêtre de conversion par lot, ses réglages de taille et la prévisualisation des fichiers.

1. **Format et taille** — Choisissez format et taille proportionnelle. Les formats avec perte proposent la qualité ; un préréglage réduit le poids.
2. **Filigrane et dossier** — Ouvrez les réglages du filigrane ou choisissez le dossier des copies.
3. **Aperçu des fichiers** — Comparez les noms actuels et futurs avant la conversion. Les originaux sont conservés.

### Marche à suivre

1. Sélectionnez avec ⌘ + clic, ⇧ + clic ou ⌘A ; dans Tout voir, tracez aussi un rectangle. Ouvrez le menu de sélection, le menu contextuel ou Image ; sur la carte, Photos de la zone, Cette photo ou Toutes les photos de ce lieu.
2. Dans Renommer par lot…, conservez, remplacez ou recherchez/remplacez le nom. Avec Utiliser un nom de classement, choisissez une étiquette : seuls les fichiers sélectionnés qui la portent changent de nom. Vérifiez l’aperçu avant/après.
3. Ouvrez Convertir, redimensionner et compresser… : réglez format, qualité, Taille de l’image et dossier. Côté le plus long ou Pourcentage réduit proportionnellement après retouches et recadrage, sans agrandissement. Réduire le poids choisit JPEG, 1920 pixels et 75 % de qualité.

### Numérotation et validité des noms

Le classement produit Envoi01, Envoi02… sans séparateur, dans l’ordre de la liste, en conservant l’extension : deux chiffres pour 1–99 fichiers concernés, trois dès 100 (001…), davantage si nécessaire. Les autres modes règlent début, incrément, chiffres et séparateur. Noms invalides ou doublons bloquent le renommage ; les images ZIP ne sont pas renommables sur place.

### Extension, format et poids

Le renommage d’extension normalise majuscules et variantes d’un format (.jpg/.jpeg, .tif/.tiff). HEIC vers JPEG nécessite une conversion de l’encodage. Le poids dépend du contenu, du format, de la qualité et des dimensions : aucun nombre d’octets garanti, et le fichier peut grossir.

### Copies converties et partage macOS

La conversion applique les retouches, conserve originaux et étiquettes, et crée des copies distinctes ; les noms existants reçoivent un numéro. Animations et images multipages donnent seulement leur première image. L’arrêt conserve les fichiers terminés et compte réussites, échecs et fichiers non traités. Partager les fichiers… envoie les originaux sans retouches d’aperçu ; Partager les fichiers terminés… envoie les copies retouchées ou réduites, même après un lot partiel. Les vidéos sont exclues de cette conversion : Images et extraits… extrait leurs PNG ou enregistre leurs extraits. Cette commande conserve aussi plusieurs images d’une animation en GIF/APNG (chapitre 13).

### Bon à savoir

- Avant ⌘A, filtrez par recherche, format, étiquettes ou carte. Vérifiez nombre et liste avant de renommer les originaux. Les services proposés, dont AirDrop, dépendent de macOS et de sa configuration.

[Retour en haut](#top)

---

<a name="watermark"></a>

## 11. Ajouter un filigrane : texte, EXIF et logo

Ajoutez texte, signature, EXIF et logo aux copies des photos sélectionnées, sans modifier les originaux ni leurs étiquettes.

![Combinez texte, EXIF et logo, déplacez le filigrane dans l’aperçu et choisissez l’extension du canevas.](figures/watermark.png)

**Écran 10.** Combinez texte, EXIF et logo, déplacez le filigrane dans l’aperçu et choisissez l’extension du canevas.

1. **Texte, police et EXIF** — Choisissez texte, police et EXIF propres à chaque photo. Ajouter des champs conserve la taille du texte.
2. **Logo et placement** — Choisissez un logo et réglez taille, marge et opacité par curseurs ou nombres.
3. **Aperçu de la première photo** — Glissez le filigrane ; le cadre d’aide n’est pas enregistré. Hors de la photo, l’extension est à confirmer.

### Marche à suivre

1. Choisissez les photos, puis Ajouter un filigrane… dans Image, les actions de sélection ou le menu contextuel. Sur la carte, l’action vise la zone ou le repère ; dans le panneau de retouche, uniquement la photo actuelle.
2. Saisissez texte ou signature. Cliquez sur le nom de la police pour choisir une police installée dans le panneau macOS. Cochez les champs EXIF ; Choisir une image… ajoute un logo ou une signature, dont les PNG transparents.
3. Choisissez une des neuf positions ou glissez le filigrane. Réglez taille, marge et opacité par curseurs ou nombres (25,5 %), texte blanc/noir et ombre/fond. Hors photo, confirmez l’extension du canevas. Cliquez sur Appliquer, réglez format, qualité, réduction et dossier, puis Lancer la conversion.

### Informations de prise de vue et taille du texte

EXIF inscrit, pour chaque photo : date, fabricant, modèle, objectif, obturation, ouverture, ISO, focale et nom du fichier. Les valeurs absentes ou illisibles sont omises. Ajouter des champs ajoute des lignes ou des retours, sans réduire le texte. Modifiez les métadonnées intégrées dans leur éditeur sous Informations sur l’image.

### Glisser et étendre le canevas

Texte et logo suivent la largeur avant extension, sans déformer le logo. La marge suit le côté court aux positions prédéfinies ; glisser fixe un centre libre. Position, taille relatives et accord d’extension valent pour la sélection : seuls les bords nécessaires sont ajoutés, sans redimensionner les photos. L’ajout est transparent avec alpha, blanc en JPEG. Garder dans l’image replace la marque à l’intérieur. Si le contenu est trop grand : Étendre le canevas, Réduire le filigrane ou Annuler, qui garde les réglages. Sans extension, le contenu doit tenir avant l’enregistrement. Revenir au canevas d’origine vérifie aussi la taille.

### Copies, aperçu et réglages mémorisés

Le filigrane suit retouches, recadrage, rotation et réduction. L’aperçu réduit de la première photo peut légèrement décaler le placement par arrondi ; dimensions et EXIF varient selon la photo. Originaux et étiquettes sont préservés ; les copies terminées se partagent via macOS. Réglages et position libre sont mémorisés, mais activez le filigrane pour chaque conversion. L’accord d’extension repart à zéro pour chaque lot ; glisser dehors demande confirmation. Gardez le logo au même chemin ; une lecture impossible est signalée. Vidéos exclues ; animations et images multipages donnent une image fixe de leur première image.

### Bon à savoir

- Texte : 2 000 caractères et 20 lignes ; logo : première image d’un fichier lisible par ImageIO. Taille : 2–90 %, marge : 0–20 %, opacité : 0–100 %. Les nombres hors plage sont bornés ; une saisie invalide garde la dernière valeur valide. Sortie étendue limitée à 64 Mpx et 32 768 px par côté ; au-delà, rapprochez ou réduisez le filigrane. Il n’apparaît pas sur l’original dans la Visionneuse.

[Retour en haut](#top)

---

<a name="video"></a>

## 12. Vidéos : lecture, images et extraits

Photos et vidéos s’affichent ensemble par défaut. Tout voir montre des aperçus vidéo fixes ; une vidéo seule s’ouvre en pause. Images et extraits… permet d’extraire un PNG ou d’enregistrer un extrait sans changer l’original.

![La fenêtre Images et extraits pour une vidéo, avec le lecteur et les réglages d’exportation.](figures/video.png)

**Écran 11.** La fenêtre Images et extraits pour une vidéo, avec le lecteur et les réglages d’exportation.

1. **Lecteur vidéo** — Lancez ou mettez en pause la vidéo pour vérifier l’image et le son.
2. **Images et position** — Parcourez les images prises en charge ou une position temporelle, puis extrayez l’image actuelle en PNG.
3. **Plage et qualité** — Définissez le début inclus, la fin exclue, le conteneur et le préréglage avant d’enregistrer une copie.

### Marche à suivre

1. En vue multiple, survolez une vidéo pour la lire sans son ; Activer le son permet de l’écouter. Quitter la vignette arrête et coupe le son. Double-cliquez une vidéo dans Tout voir ou la Visionneuse : elle se lit seule en plein écran, à la même position et avec le même réglage sonore. Ajustez lecture, position et son avec les commandes. Échap ou Fermer le plein écran retrouve la disposition initiale.
2. Dans Images et extraits…, déplacez la position de lecture ou utilisez Image précédente / Image suivante si la vidéo le permet. Le déplacement suit les images réelles ; aucun compte exact n’est déduit d’une fréquence variable.
3. Choisissez Extraire l’image actuelle en PNG… pour l’image affichée. Pour un extrait, définissez Début (s) et Fin (s), éventuellement avec Définir le début ici / Définir la fin ici, puis choisissez MP4 ou MOV, la qualité et Enregistrer une copie de l’extrait….

### Formats disponibles sur ce Mac

La prise en charge dépend des conteneurs et des codecs que la version de macOS installée peut effectivement décoder : MP4, MOV et d’autres formats natifs peuvent fonctionner, sans installation de codecs externes. Une extension seule ne garantit pas la lecture. WebM, MKV et les vidéos contenues dans les ZIP ne sont pas pris en charge. L’enregistrement d’images ou d’extraits est indisponible pour les vidéos protégées par DRM. Les données GPS des vidéos ne sont pas utilisées pour la carte.

### Plage et qualité de la copie

Le début est inclus et la fin exclue ; les limites réellement enregistrées suivent les échantillons du média. L’extrait est réencodé en H.264/AAC dans un conteneur MP4 ou MOV, en conservant le fichier d’origine. Préréglage de réduction de taille choisit MP4 et un maximum de 720p. Les préréglages de qualité et de résolution n’agrandissent pas les petites vidéos et ne garantissent pas un fichier plus petit : le résultat peut être plus volumineux. L’extraction PNG conserve la résolution de l’image source ; la qualité choisie s’applique uniquement aux copies d’extraits.

### Fonctions réservées aux images

Les retouches photo, l’agrandissement IA, le fond d’écran et la conversion d’images par lot ne s’appliquent pas aux vidéos. La Comparaison d’images reste limitée aux images. Un album photo ne démarre pas si la liste affichée contient une vidéo ; désactivez Afficher les vidéos pour utiliser le diaporama avec les images seules. Les étiquettes, le renommage et le partage des originaux sélectionnés restent disponibles pour les vidéos. Les nouvelles copies n’héritent pas des étiquettes de l’original.

### Bon à savoir

- Choisissez un nouveau nom : le fichier d’origine et les fichiers déjà présents ne sont pas écrasés. Une annulation supprime la copie incomplète. Les résultats enregistrés avec succès peuvent être partagés avec le partage macOS.

[Retour en haut](#top)

---

<a name="animation"></a>

## 13. Parcourir et enregistrer les images d’une animation

Images et extraits… permet de parcourir les animations GIF, APNG et WebP que ce Mac peut décoder, d’en extraire un PNG et d’enregistrer une plage en GIF ou APNG.

![La fenêtre Images et extraits pour une animation, avec l’aperçu, les images et les dimensions de sortie.](figures/animation.png)

**Écran 12.** La fenêtre Images et extraits pour une animation, avec l’aperçu, les images et les dimensions de sortie.

1. **Aperçu de l’animation** — Contrôlez l’image affichée et le mouvement avant de sauvegarder.
2. **Navigation dans les images** — Avancez ou reculez d’une image et extrayez l’image actuelle en PNG.
3. **Plage et dimensions** — Choisissez une plage inclusive, GIF ou APNG, la taille et les images à conserver.

### Marche à suivre

1. Ouvrez une animation prise en charge, puis choisissez Images et extraits…. Les GIF restent visibles même si Afficher les vidéos est désactivé. Vérifiez l’aperçu et utilisez Lire / Pause ou les commandes d’image précédente et suivante.
2. Choisissez Extraire l’image actuelle en PNG… pour obtenir une image fixe. Pour enregistrer une plage animée, indiquez Première image et Dernière image : la numérotation commence à 1 et les deux limites sont incluses.
3. Choisissez GIF ou APNG selon les formats proposés sur ce Mac. Réglez la taille et les Images à conserver, puis utilisez Enregistrer une copie de l’extrait… pour créer un nouveau fichier.

### Images conservées et durée

Vous pouvez garder toutes les images ou une image sur 2, 3 ou 4 dans la plage choisie. La durée des images omises est ajoutée à celle d’une image conservée, afin de préserver la durée totale de la plage plutôt que d’accélérer l’animation.

### Dimensions et réduction du poids

Conservez la Taille d’origine, fixez le Côté le plus long en pixels ou utilisez un Pourcentage de 1 à 100 %. Les proportions sont conservées et les petites images ne sont pas agrandies. Préréglage de réduction de taille choisit 50 % et une image sur 2. Le poids dépend du contenu et du format ; la réduction n’est pas garantie. L’extraction PNG conserve la résolution de l’image source ; les réglages de taille et d’images à conserver s’appliquent uniquement aux copies animées.

### Formats et rendu

La lecture GIF, APNG ou WebP et les formats de sortie proposés dépendent des capacités de décodage et d’encodage de ce Mac. Les copies animées se limitent au GIF et à l’APNG. Le GIF limite les couleurs et la transparence : l’aspect peut donc changer. Les retouches photo actuellement affichées ne sont appliquées ni à l’extraction de l’image ni à la copie animée.

### Bon à savoir

- L’original est conservé et les noms de fichiers déjà utilisés sont refusés. Annuler supprime une sortie incomplète. Après une sauvegarde réussie, utilisez le partage macOS pour partager la copie terminée. Les nouvelles copies n’héritent pas des étiquettes de l’original.

[Retour en haut](#top)

---

<a name="ai-upscaling"></a>

## 14. Zoomer et comparer le résultat de l’agrandissement IA

Agrandissement IA crée une nouvelle image dont la largeur et la hauteur sont doublées. Examinez ses détails et comparez la même zone avec l’original avant d’enregistrer une copie PNG.

![L’aperçu permet de régler le zoom et de déplacer une séparation pour comparer la même zone de l’original et du résultat IA.](figures/ai-upscaling.png)

**Écran 13.** L’aperçu permet de régler le zoom et de déplacer une séparation pour comparer la même zone de l’original et du résultat IA.

1. **Vue et zoom** — Choisissez Résultat de l’agrandissement IA ou Comparer à l’original. Examinez les détails avec +/−, le pourcentage, Ajuster à la fenêtre et 100% · Pixels réels.
2. **Séparation original et IA** — Déplacez la séparation entre l’original à gauche et le résultat IA à droite. Glisser l’image ou faire défiler déplace les deux côtés ensemble.
3. **Enregistrer une copie PNG** — Enregistrez le résultat 2× complet en copie PNG, indépendamment du zoom de l’aperçu.

### Marche à suivre

1. Sélectionnez une photo, ouvrez Agrandissement IA… et cliquez sur Lancer l’agrandissement IA. Une fois le traitement terminé, l’aperçu affiche le Résultat de l’agrandissement IA.
2. Utilisez les boutons +/− ou le pincement du trackpad pour zoomer. Faites glisser l’image ou faites défiler pour examiner un détail ; Ajuster à la fenêtre réaffiche l’image entière.
3. Sélectionnez Comparer à l’original et déplacez la séparation vers la gauche ou la droite. L’original est à gauche et le résultat IA à droite, avec le même zoom et la même position. Après vérification, cliquez sur Enregistrer une copie PNG….

### Que signifie 100% · Pixels réels ?

À 100%, un pixel du résultat IA correspond à un pixel physique de l’écran. Le calcul tient compte de la mise à l’échelle Retina : la taille de la fenêtre en points ne correspond donc pas nécessairement aux dimensions de l’image en pixels. Le pourcentage se rapporte au résultat IA, et non à l’original. Ajuster à la fenêtre choisit un zoom qui montre l’image entière. Ces commandes modifient seulement l’aperçu : elles ne redimensionnent pas le fichier, ne changent pas le résultat enregistré et ne relancent pas le traitement IA.

### Comparer le même détail

L’original de gauche est affiché à 2× par interpolation classique pour avoir la même largeur et la même hauteur que le résultat IA. Les deux côtés partagent le zoom et le déplacement ; la séparation permet donc de comparer les mêmes contours et textures. Faites glisser la séparation pour déplacer la limite de comparaison, ou une autre partie de l’image pour la déplacer. Les détails créés par l’IA sont une estimation ; la récupération d’informations réelles absentes de l’original n’est pas garantie.

### Résultat et limites de l’IA

Le modèle fourni fonctionne localement avec Core ML : les photos ne sont pas téléversées et aucun modèle n’est téléchargé pendant l’utilisation. La largeur et la hauteur sont doublées. Le résultat est un PNG sRGB SDR 8 bits, avec une transparence interpolée séparément. Une animation utilise sa première image et les retouches de la visionneuse sont exclues. La sortie est limitée à 64 millions de pixels au maximum, avec une limite potentiellement inférieure sur les Mac peu dotés en mémoire. Enregistrez avant de fermer ; les détails IA sont une estimation.

### Bon à savoir

- L’IA 4×, la sortie HDR par IA et l’agrandissement IA par lot ne sont pas proposés. Enregistrez une copie PNG avant de fermer. Le fichier original reste inchangé.

[Retour en haut](#top)

---

<a name="quality"></a>

## 15. Comprendre la qualité d’affichage, le HDR et le chargement

Zoom haute qualité change l’interpolation d’affichage. Agrandissement IA crée une image plus grande à enregistrer. La sortie HDR est une préférence d’affichage, pas une preuve que la photo est HDR.

### Marche à suivre

1. Pour un affichage plus lisse, activez Zoom haute qualité. Sa comparaison côte à côte ou de haut en bas montre la même photo avec zoom et déplacement liés ; Esc ferme cette comparaison.
2. Utilisez les commandes de sortie HDR activée/désactivée pour autoriser ou non l’affichage étendu. Dans Réglages → Général → Chargement des images, choisissez Prioritaire, Confortable, Normal ou Lent selon votre usage.

### Formats et performances

Les formats lisibles et inscriptibles dépendent du macOS exécuté. L’application ajoute le décodage QOI et des variantes PCX courantes, ainsi qu’une solution de repli SVG/SVGZ. BPG et .clip ne sont pas inclus. Confortable est le mode de chargement par défaut. Tous les modes ralentissent en cas de pression mémoire, de chaleur, de mode économie d’énergie, d’autres applications actives ou de stockage plus lent.

### Bon à savoir

- Pendant une navigation rapide, un petit aperçu ou la photo précédente peut rester visible jusqu’à ce que l’image finale soit prête.

[Retour en haut](#top)

---

<a name="slideshow"></a>

## 16. Lire un album photo ou définir le fond d’écran

Album photo fait défiler automatiquement la liste actuelle, une image à la fois en mode concentration. Le fond d’écran utilise une copie distincte préparée pour les écrans choisis.

### Marche à suivre

1. Ouvrez une liste contenant au moins deux photos. Choisissez Navigation → Album photo → Lire l’album photo ou appuyez sur ⌃⌥P. La liste doit contenir uniquement des images : si une vidéo y figure, désactivez Afficher les vidéos avant de démarrer l’album.
2. Utilisez les commandes de lecture pour mettre en pause. Choisissez un intervalle de 1 à 300 secondes et la répétition, avec la commande de durée ou dans Réglages → Général → Album photo.
3. Pour définir un fond d’écran, revenez à la visionneuse normale et choisissez Image → Utiliser l’image actuelle comme fond d’écran… ou appuyez sur ⌃⌥W. Choisissez l’écran actuel ou tous les écrans connectés, Remplir l’écran ou Afficher toute la photo, et l’application éventuelle des réglages actuels ; puis appliquez.

### Déroulement de la lecture

L’intervalle par défaut est de cinq secondes avec répétition. Le décompte commence après l’affichage d’un aperçu ou de l’image : le chargement ne réduit donc pas le temps de visionnage. Une navigation manuelle ou un changement d’intervalle relance le décompte. Sans répétition, la lecture s’arrête sur la dernière image.

### Pauses automatiques

La lecture se met en pause en quittant le mode concentration, en changeant d’application, lors de la mise en veille ou au début d’une opération sur les fichiers. L’écran reste éveillé uniquement pendant la lecture. Au prochain lancement, les réglages sont restaurés mais la lecture ne démarre jamais automatiquement.

### Copies de fond d’écran

L’application crée un PNG sans modifier la source. Elle prend la première image des animations et prépare le HDR en SDR. Les copies excluent EXIF/GPS, sont dimensionnées pour l’écran jusqu’à 8192 pixels et restent dans le dossier Application Support/Wallpapers de l’application. Les autres espaces de bureau suivent le comportement de macOS. Les anciennes copies ne sont pas supprimées automatiquement, car un autre espace peut encore les utiliser. Les vidéos ne peuvent pas servir de source au fond d’écran.

### Bon à savoir

- Si la lecture est indisponible, vérifiez que la liste filtrée contient au moins deux photos et que le marquage, la Comparaison d’images ou une autre opération ne sont pas actifs. La liste doit contenir uniquement des images : si une vidéo y figure, désactivez Afficher les vidéos avant de démarrer l’album.

[Retour en haut](#top)

---

<a name="settings"></a>

## 17. Adapter l’application à vos habitudes

Les réglages réunissent l’affichage quotidien, les raccourcis personnalisés, les étiquettes et les associations de fichiers. De nombreux choix reviennent automatiquement au lancement suivant.

![Les réglages regroupent les principales préférences dans quatre onglets.](figures/settings.png)

**Écran 14.** Les réglages regroupent les principales préférences dans quatre onglets.

1. **Onglets des réglages** — Général, Raccourcis, Étiquettes photo et Associations de fichiers correspondent chacun à une tâche.
2. **Préférences d’affichage** — Réglez l’écran, les vignettes, les noms de fichiers, la navigation et le chargement.
3. **Explications intégrées** — Lisez le texte sous une commande ou survolez-la pour connaître son fonctionnement.

### Marche à suivre

1. Ouvrez 알맹Re → Réglages…. Dans Général, choisissez la sortie HDR/EDR, la position des vignettes, la taille des noms de fichiers, le zoom haute qualité, l’affichage de l’arborescence et le retour au début après la dernière image.
2. Dans Étiquettes photo, enregistrez les noms et couleurs communs ; dans Raccourcis, choisissez les touches et combinaisons de modificateurs. Survolez les commandes pour lire leurs explications.
3. Pour que le Finder ouvre certains formats avec cette application, placez 알맹Re.app à un emplacement stable, comme Applications, ouvrez Associations de fichiers, cochez seulement les groupes de formats souhaités et appliquez.

### Langue

L’interface suit la langue attribuée à l’app par macOS. Modifiez-la dans Réglages Système → Général → Langue et région → Applications, puis relancez l’app. Langues prises en charge : coréen, anglais, japonais, chinois simplifié, vietnamien, espagnol, français, allemand, russe et arabe. L’aide de base suit la langue de l’app. Les guides détaillés existent en sept langues ; en allemand, russe ou arabe, le guide anglais s’ouvre.

### Préférences mémorisées

La taille des vignettes, le zoom haute qualité, les noms de fichiers, le chargement, les favoris, les étiquettes et les raccourcis sont conservés. Reprendre la session précédente sur l’accueil restaure la collection et la position si les fichiers restent accessibles. La comparaison de qualité du zoom est désactivée au prochain lancement. Retouches visuelles et résultats IA doivent être exportés séparément. Afficher les vidéos est activé par défaut et mémorise votre choix sans affecter les GIF.

### Associations de fichiers

Seuls les groupes de formats cochés sont modifiés. macOS peut demander confirmation. Déplacer l’application ou conserver d’anciennes copies peut amener le Finder à ouvrir la mauvaise version ; réappliquez les associations depuis celle que vous voulez utiliser.

### Bon à savoir

- Général répertorie aussi les formats natifs disponibles sur votre Mac et propose Vider le cache d’images. Choisissez un mode de chargement plus lent pour réduire le travail en arrière-plan pendant l’utilisation d’autres applications. Les vignettes RAW utilisent les aperçus intégrés lorsqu’ils sont disponibles. Les vignettes de taille suffisante sont réutilisées entre les modes de vue. La vitesse du premier affichage dépend du fichier et du Mac.

[Retour en haut](#top)

---

<a name="shortcuts"></a>

## 18. Raccourcis et dépannage rapide

Le tableau suivant indique les touches d’action par défaut et les touches contextuelles fixes. ⌘ signifie Commande, ⌥ Option, ⌃ Contrôle et ⇧ Maj.

![L’onglet Raccourcis présente les actions configurables et les conflits.](figures/shortcuts.png)

**Écran 15.** L’onglet Raccourcis présente les actions configurables et les conflits.

1. **Actions** — Survolez le nom d’une action pour savoir où et comment elle fonctionne.
2. **Touches et modificateurs** — Choisissez la touche, puis activez Contrôle, Option, Maj ou Commande.
3. **Conflits et valeurs par défaut** — Résolvez les doublons ou utilisez Rétablir les valeurs par défaut pour recommencer.

### Marche à suivre

1. Ouvrez Réglages → Raccourcis pour modifier la touche et les modificateurs d’une action. Les changements sont enregistrés et les affectations actuelles apparaissent dans les menus.
2. Vérifiez les indicateurs de conflit si une combinaison est attribuée à plusieurs actions. Survolez l’action, le sélecteur de touche, le modificateur ou l’icône de conflit pour obtenir de l’aide. Rétablir les valeurs par défaut réinitialise les touches d’action configurables.
3. Si une touche agit autrement que prévu, quittez le champ de texte et vérifiez le mode actuel. Le marquage réserve ses douze touches aux étiquettes ; la Comparaison d’images donne aux flèches avec Option leur rôle de navigation A/B.

### Aucune image ou correspondance

Effacez les filtres de recherche, format, étiquettes et carte. Vérifiez que ce macOS peut lire le format d’entrée. Un dossier vide peut être ouvert pour parcourir ses sous-dossiers. Utilisez Ouvrir… pour retrouver un disque déconnecté ou une collection déplacée.

### Commande désactivée

Terminez ou annulez d’abord l’opération en cours sur les fichiers. Quittez la Comparaison d’images pour retoucher, convertir par lot ou définir le fond d’écran. Les images ZIP ne peuvent être renommées ni voir leurs métadonnées source réécrites. Les boutons de résultats de carte attendent une sélection non vide et entièrement calculée.

### Espace, Esc et flèches avec Option

Espace sert au mode concentration uniquement si aucune action personnalisée n’utilise Espace seul et si vous ne saisissez pas de texte. Esc quitte le mode actif ou annule un geste de sélection. Dans la Visionneuse, la navigation par page avec Option est fixe mais cède la priorité à une action personnalisée de la visionneuse normale utilisant la même combinaison.

### Bon à savoir

- Les boutons i circulaire et en forme de curseurs ouvrent les informations photo et la retouche. Utilisez les boutons ou le menu Navigation ; I et E ne sont pas les raccourcis par défaut de ces panneaux dans cette version.

[Retour en haut](#top)

---

<a name="shortcut-reference"></a>

## Les raccourcis en un regard

| Touches | Action | Conditions d’utilisation |
| --- | --- | --- |
| ← / → | Image ou page précédente / suivante | Configurable. La Visionneuse normale avance d’une page ; Marquage ON et Tout voir, d’un élément. La comparaison suit A seul / Les deux / B seul. |
| ↑ / ↓ | Sélectionner la ligne au-dessus / en dessous | Dans Tout voir et la Visionneuse à plusieurs éléments, avec Marquage ON ou OFF. La Visionneuse reste dans la page actuelle. Arrêt aux lignes extrêmes ; raccourcis personnalisés prioritaires sur OFF. |
| ⌥← / ⌥→ | Page précédente / suivante de la visionneuse | Touches contextuelles fixes lorsque plusieurs images sont affichées, y compris pendant le marquage ; les raccourcis personnalisés de la visionneuse sont prioritaires. |
| = / − | Zoom avant / arrière | Configurable ; concerne la visionneuse normale ou le volet de comparaison actif. |
| 0 / 1 | Adapter à la fenêtre / Taille réelle | Configurable. La touche 1 seule sert d’étiquette pendant le marquage. |
| G | Activer/désactiver Tout voir | Action d’affichage configurable. |
| F | Activer/désactiver le mode concentration | Configurable. La touche F seule sert d’étiquette pendant le marquage. |
| Space (tap) | Activer/désactiver le mode concentration | Geste de la Visionneuse ; inactif pendant la saisie ou si une action personnalisée utilise Espace. Maintenir Espace pour déplacer l’image ne change pas le mode concentration. |
| ⌃⌘F | Activer/désactiver Plein écran | Raccourci fixe du menu de l’application, distinct du mode concentration. |
| \[ / \] | Afficher moins / plus d’images par vue | Configurable ; de 1 à 10 dans la Visionneuse. |
| ⌘O | Ouvrir des images, dossiers ou archives ZIP | Configurable ; en comparaison, ouvre dans le volet actif déverrouillé. |
| ⌘E | Exporter l’image actuelle | Configurable ; concerne la visionneuse normale et reste indisponible en Comparaison d’images. |
| ⌃⌥1 | Choisir le déplacement par glissement gauche | Configurable ; sélectionne une méthode au lieu de déplacer l’image. |
| ⌃⌥2 | Choisir Espace + glissement gauche | Sélection configurable de la méthode de déplacement. |
| ⌃⌥3 | Choisir le déplacement avec le bouton droit | Sélection configurable de la méthode de déplacement. |
| ⌃⌥4 | Choisir le déplacement avec le bouton central | Sélection configurable de la méthode de déplacement. |
| ⌃⌥5 | Choisir le déplacement à deux doigts sur le trackpad | Sélection configurable de la méthode de déplacement. |
| ⌃⌥A | Activer/désactiver Zoom haute qualité | Réglage d’affichage configurable ; ne modifie pas les fichiers exportés. |
| ⌃⌥6 / ⌃⌥7 | Comparer la qualité du zoom côte à côte / de haut en bas | Configurable ; deux rendus de la même image dans la Visionneuse. |
| ⌃⌥0 | Quitter la comparaison de qualité du zoom | Configurable ; Esc ferme aussi cette comparaison. |
| ⌃⌥P | Lire / mettre en pause Album photo | Configurable ; nécessite au moins deux photos et la disponibilité de la visionneuse normale. |
| ⌃⌥W | Utiliser l’image actuelle comme fond d’écran | Configurable ; ouvre les options de fond d’écran hors de la Comparaison d’images. |
| ⌃⌥C | Ouvrir / quitter la Comparaison d’images | Configurable ; conserve la collection précédente de la visionneuse normale. |
| ⌥← / ⌥→ | Image précédente / suivante dans A uniquement | Action de comparaison configurable ; A est à gauche ou en haut. Un volet verrouillé reste fixe. |
| ⇧⌥← / ⇧⌥→ | Image précédente / suivante dans B uniquement | Action de comparaison configurable ; B est à droite ou en bas. Un volet verrouillé reste fixe. |
| ⌘⇧M | Activer/désactiver le mode marquage | Raccourci fixe du menu de l’application. |
| 1 2 3 4 · Q W E R · A S D F | Ajouter/retirer les douze étiquettes de photos et vidéos | Touches physiques fixes, élément actuel seulement avec Marquage ON ; en plein écran, la vidéo affichée. Aucune suppression ni aucun téléversement. |
| ← / → · ↑ / ↓ | Parcourir les éléments / lignes pendant le marquage | ←/→ avance d’un élément ; ↑/↓ d’une ligne dans la grille. Dans la Visionneuse à un élément et la Comparaison d’images, ↑/↓ passe à l’élément précédent ou suivant. |
| ⌘A | Sélectionner toutes les images de la liste actuelle | Raccourci fixe de sélection hors Comparaison d’images ; les champs de texte conservent leur sélection de texte habituelle. |
| Esc | Annuler le geste ou quitter le mode actif | Fixe. Quitte le marquage, la comparaison, la comparaison de qualité du zoom ou le mode concentration ; la Visionneuse normale revient à Tout voir. Annule aussi les gestes de sélection de zone. |

[Retour en haut](#top)
