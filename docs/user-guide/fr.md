<!-- almeng-guide-source-sha256: 7c91246c7888403265139f94271b713571028d2e89311e8119c1a9e2e95ec38c -->

<a name="top"></a>

# Guide d’utilisation d’알맹Re

[한국어](ko.md) · [English](en.md) · [日本語](ja.md) · [简体中文](zh-Hans.md) · [Français](fr.md) · [Español](es.md) · [Tiếng Việt](vi.md)

[← 알맹Re](../../README.md) · [PDF](pdf/AlmaengRe-User-Guide-fr.pdf)

**Ouvrir, parcourir, comparer, étiqueter et retoucher vos images sur Mac**

Un guide pratique de la version de développement 0.12 actuelle. Commencez par ouvrir un dossier d’images, puis consultez le chapitre correspondant à votre tâche. Les noms de menus de ce guide reprennent ceux de l’interface française.

Version 0.12.0 · Au 2026-10-05

> Les captures montrent l’application réelle avec une interface coréenne et des images de démonstration synthétiques. Les annotations numérotées et les explications sont traduites en français ; les pixels des captures restent inchangés. Aucune collection de photos personnelle n’est utilisée.

## Sommaire

- [1. Ouvrir des images, des dossiers et des archives ZIP](#open)
- [2. Parcourir les images et se concentrer sur une photo](#viewer)
- [3. Rechercher et sélectionner dans Tout voir](#overview)
- [4. Comparer deux collections d’images](#compare)
- [5. Étiqueter les photos au clavier](#tags)
- [6. Définir les noms, couleurs et règles de suivi des étiquettes](#tag-editor)
- [7. Retrouver les photos par lieu](#map)
- [8. Examiner les informations et les métadonnées](#information)
- [9. Retoucher une image et exporter une copie](#editing)
- [10. Renommer, redimensionner, convertir et partager en lot](#batch)
- [11. Comprendre l’agrandissement IA, le HDR et le chargement](#quality)
- [12. Lire un album photo ou définir le fond d’écran](#slideshow)
- [13. Adapter l’application à vos habitudes](#settings)
- [14. Raccourcis et dépannage rapide](#shortcuts)
- [Les raccourcis en un regard](#shortcut-reference)

---

<a name="open"></a>

## 1. Ouvrir des images, des dossiers et des archives ZIP

La commande Ouvrir… accepte tous les types d’entrée. Une photo, un dossier ou une archive ZIP se parcourent ensuite de la même manière.

### Marche à suivre

1. Lancez 알맹Re sous macOS 14 ou ultérieur. Choisissez Ouvrir… sur l’écran d’accueil, dans la barre d’outils ou dans le menu Fichier, ou appuyez sur ⌘O.
2. Choisissez un dossier pour parcourir ses images. Choisissez une seule image pour commencer par celle-ci et poursuivre avec les autres images du même dossier. Si vous sélectionnez plusieurs images, seules celles-ci sont ouvertes.
3. Choisissez une archive ZIP pour afficher ses images prises en charge, y compris celles de ses sous-dossiers. Vous pouvez aussi ouvrir des fichiers depuis le Finder ou déposer des images et des dossiers dans l’application.

### Dossiers et favoris

L’arborescence des dossiers se développe selon vos besoins. Cliquez sur un nom de dossier pour l’ouvrir, utilisez la flèche vers le haut pour remonter et actualisez après des changements dans le Finder. Épinglez un dossier au-dessus de l’arborescence pour y accéder rapidement. Ouvrir un dossier ordinaire n’inclut pas automatiquement tous ses sous-dossiers.

### ZIP en lecture seule

Les images sont extraites dans un dossier temporaire tant que l’archive est ouverte. Exportez une copie avant de renommer un fichier ou de modifier ses métadonnées source. L’application ne réécrit pas le ZIP. Les archives sans compression ou utilisant Deflate sont prises en charge ; les archives chiffrées et les autres méthodes de compression sont refusées. Les limites sont de 2 Gio par archive, 10 000 entrées, 256 Mio par entrée extraite et 1 Gio de données extraites au total.

### Retrouver votre position

L’application restaure, si possible, la dernière collection, l’image sélectionnée, le mode d’affichage et la recherche. Si un disque est déconnecté ou si les autorisations ont changé, utilisez de nouveau Ouvrir…. Les retouches et les résultats IA non enregistrés ne sont pas restaurés.

### Bon à savoir

- La sélection simultanée de dossiers et d’images individuelles les rassemble sans doublons. En Comparaison d’images, Ouvrir… remplace le contenu du volet A ou B actif et déverrouillé. Aide → Utilisation de base ouvre un bref mode d’emploi dans l’application. Aide → Guide détaillé (GitHub) ouvre le guide complet dans votre langue sur GitHub, dans votre navigateur par défaut.

[Retour en haut](#top)

---

<a name="viewer"></a>

## 2. Parcourir les images et se concentrer sur une photo

La Visionneuse affiche de une à dix images à la fois. Agrandissez les détails ou masquez les commandes environnantes pour vous concentrer sur la photo.

![La Visionneuse principale, avec ses commandes autour de l’image.](figures/viewer.png)

**Écran 01.** La Visionneuse principale, avec ses commandes autour de l’image.

1. **Modes d’affichage** — Passez entre Visionneuse, Tout voir, Vue carte et Comparaison d’images.
2. **Rechercher et organiser** — Recherchez des noms de fichiers et utilisez les commandes de format, d’étiquettes et de tri de la collection ouverte.
3. **Commandes d’affichage** — Parcourez les images, réglez le zoom, changez le nombre affiché et choisissez une méthode de déplacement.

### Marche à suivre

1. Choisissez Visionneuse en haut. Utilisez ← et → pour naviguer. Réglez le nombre d’images par vue avec la commande correspondante ou \[ et \] ; la grille s’adapte à la forme de la fenêtre.
2. Pincez le trackpad ou utilisez = et − pour zoomer. Appuyez sur 0 pour Adapter à la fenêtre et sur 1 pour Taille réelle. Choisissez une commande de déplacement dans les commandes inférieures ou dans Réglages → Général.
3. Appuyez sur F, double-cliquez sur une photo ou touchez brièvement Espace pour activer ou quitter le mode concentration. Appuyez sur Esc pour revenir. Plein écran est une commande distincte : ⌃⌘F.

### Parcourir plusieurs images

Dans la visionneuse normale, ←/→ avance du nombre d’images défini par vue. ⌥←/⌥→ déplace également une vue entière lorsque plusieurs images sont affichées. En mode marquage, les flèches seules avancent d’une photo, tandis que les flèches avec Option déplacent toujours une vue entière.

### Commandes de déplacement

Choisissez le glissement avec le bouton gauche, Espace + bouton gauche, le bouton droit, le bouton central ou le déplacement à deux doigts. Les raccourcis ⌃⌥1–5 sélectionnent une méthode ; ils ne déplacent pas la photo eux-mêmes. Les balayages horizontaux changent d’image lorsque le geste n’est pas utilisé pour déplacer la photo.

### Commandes du mode concentration

Le × inférieur masque uniquement la barre de commandes flottante. Rouvrez-la avec le bouton à côté du nom de fichier. Le × supérieur quitte le mode concentration. Ces boutons restent disponibles même lorsque les noms de fichiers sont masqués. Une brève pression sur Espace ne change pas le mode pendant la saisie ou si cette touche possède un raccourci personnalisé.

### Bon à savoir

- Les vignettes peuvent apparaître à gauche, à droite, en haut ou en bas, ou être masquées. Esc ferme d’abord le mode d’affichage temporaire actif, puis permet de revenir de la Visionneuse à Tout voir.

[Retour en haut](#top)

---

<a name="overview"></a>

## 3. Rechercher et sélectionner dans Tout voir

Tout voir présente la collection actuelle sous forme de grille de vignettes. Utilisez-la pour examiner un dossier, affiner une sélection et préparer une opération par lot.

![Tout voir réunit la grille de vignettes, la recherche et les commandes de sélection et de taille.](figures/overview.png)

**Écran 02.** Tout voir réunit la grille de vignettes, la recherche et les commandes de sélection et de taille.

1. **Grille de vignettes** — Cliquez, sélectionnez une plage ou faites glisser sur les cartes ; double-cliquez pour ouvrir une photo.
2. **Recherche et filtres** — Affinez la collection ouverte sans modifier les fichiers.
3. **Taille et sélection** — Réglez la taille des aperçus et utilisez les actions sur les images sélectionnées pour les opérations par lot.

### Marche à suivre

1. Choisissez Tout voir ou appuyez sur G. Réglez la taille des vignettes pour afficher plus d’images ou des aperçus plus grands. Double-cliquez sur une vignette pour l’ouvrir dans la Visionneuse.
2. Saisissez du texte dans Rechercher un nom de fichier. La recherche ignore les majuscules ; chaque terme séparé par une espace doit apparaître dans le nom. Choisissez un ou plusieurs formats, ou Tous les formats pour effacer ce filtre.
3. Cliquez pour sélectionner, utilisez ⌘ + clic pour ajouter ou retirer une image, et ⇧ + clic pour sélectionner une plage. Faites glisser un rectangle depuis une image ou une zone vide pour sélectionner les cartes qu’il touche.

### Raccourcis de sélection

Maintenez Maj au début du tracé d’un rectangle pour ajouter à la sélection. Maintenez ⌘ pour inverser la sélection des images dans le rectangle. Esc restaure la sélection précédant ce glissement. ⌘A sélectionne toutes les images de la liste actuellement visible.

### Trier la liste actuelle

Triez par nom, date de modification, date de création, taille de fichier ou direction GPS. Le tri par nom place 2 avant 10. Le tri GPS lit les métadonnées de position et place les images sans GPS à la fin. La recherche et les restrictions de format, d’étiquette et de carte se combinent ; aucune ne modifie les fichiers originaux.

### Numéros et taille des aperçus

La commande # affiche ou masque les numéros des vignettes. Les grands numéros sont déplacés hors des petites photos pour préserver leur visibilité. La taille des vignettes est mémorisée ; sa plage est de 44,8 à 665,6 points, chaque cellule restant limitée par la largeur de la fenêtre.

### Bon à savoir

- La recherche porte sur le nom du fichier, pas sur les objets, le contenu visuel ou le texte OCR. Si des images attendues disparaissent, effacez la recherche et les filtres actifs avant de rouvrir le dossier.

[Retour en haut](#top)

---

<a name="compare"></a>

## 4. Comparer deux collections d’images

La Comparaison d’images conserve deux collections indépendantes, A et B, côte à côte ou l’une au-dessus de l’autre. Elle permet de comparer des versions ou de vérifier deux dossiers.

![Deux collections dans la Comparaison d’images.](figures/compare.png)

**Écran 03.** Deux collections dans la Comparaison d’images.

1. **Volets A et B** — Chaque volet possède sa propre collection d’images et sa commande Ouvrir….
2. **Comportement de la comparaison** — Choisissez la méthode d’association, la cible de navigation, la répétition du côté le plus court et la liaison du zoom.
3. **Verrous et vignettes** — Figez un côté ou choisissez une autre image dans sa bande de vignettes.

### Marche à suivre

1. Choisissez Comparaison d’images ou appuyez sur ⌃⌥C. Utilisez Choisir les dossiers à comparer… pour sélectionner A puis B, ou le bouton Ouvrir… de chaque volet.
2. Utilisez Ordre de la liste pour des listes indépendantes. Choisissez Noms identiques pour associer les noms sans leur extension : 001.jpg correspond à 001.png. Les correspondances absentes apparaissent comme des cases vides.
3. Sous Navigation des images, choisissez A seul, Les deux ou B seul. Utilisez les flèches communes ou les vignettes d’un volet pour avancer. Activez Lier zoom et déplacement pour examiner les mêmes positions relatives.

### Navigation et répétition

Choisir A seul ou B seul passe à Ordre de la liste. Noms identiques rétablit la navigation par paires. Avec Les deux, Boucler le côté le plus court répète la liste la plus courte pendant que la plus longue avance ; sinon, la plus courte conserve sa dernière image. Cette répétition concerne Ordre de la liste.

### Verrouillage

Verrouiller fige l’image, le zoom et la position d’un volet. Verrouillez B pour parcourir A, ou A pour parcourir B. Déverrouiller les deux rétablit la navigation Les deux ; verrouiller les deux arrête la navigation. Les vignettes d’un volet verrouillé restent consultables et défilables.

### Originaux et état mémorisé

La comparaison affiche les originaux sans les retouches de la visionneuse normale. Quittez-la pour retoucher, effectuer des opérations par lot ou définir un fond d’écran. Esc revient à la vue précédente. La disposition, la liaison, les préférences de navigation ainsi que les dernières entrées et positions A/B sont mémorisées.

### Bon à savoir

- ⌥←/⌥→ parcourt A uniquement ; ⇧⌥←/⇧⌥→ parcourt B uniquement. Noms identiques ignore l’extension, les majuscules et les écritures Unicode équivalentes.

[Retour en haut](#top)

---

<a name="tags"></a>

## 5. Étiqueter les photos au clavier

Le marquage permet d’ajouter plusieurs étiquettes personnelles à une photo pendant la navigation. Ce sont des marques dans l’application, pas des actions sur le fichier original.

![Le mode marquage, ses touches et ses étiquettes colorées.](figures/tags.png)

**Écran 04.** Le mode marquage, ses touches et ses étiquettes colorées.

1. **Mode marquage** — Activez ou désactivez le mode ; les touches d’affichage habituelles reprennent leur rôle lorsqu’il est désactivé.
2. **Touches d’étiquettes** — Utilisez 1–4, QWER et ASDF ou cliquez sur une étiquette. Une photo peut porter plusieurs marques.
3. **Filtre Étiquettes** — Rassemblez les photos correspondantes ou sans étiquette dans la collection actuellement ouverte.

### Marche à suivre

1. Ouvrez des photos et cliquez sur Marquage, utilisez le menu Étiquettes des photos ou appuyez sur ⌘⇧M. En Comparaison d’images, les étiquettes concernent la photo du volet actif.
2. Parcourez avec ← et →. Appuyez sur les touches physiques 1–4, QWER ou ASDF pour ajouter ou retirer leurs étiquettes. Une nouvelle pression retire l’étiquette ; plusieurs peuvent coexister.
3. Quittez le marquage avec ⌘⇧M, Esc ou le bouton de fermeture du panneau. Utilisez le filtre Étiquettes pour afficher Au moins une étiquette choisie, Toutes les étiquettes choisies ou Photos sans étiquette.

### Garder un rythme régulier

Ajouter une étiquette ne fait pas avancer automatiquement. Pendant le marquage, la liste filtrée reste en place afin que plusieurs touches concernent la même image. Les résultats sont actualisés à la sortie du mode. Les flèches seules avancent d’une photo à la fois dans ce mode.

### Signification des touches

Les noms initiaux, dont Supprimer et Téléverser, ne sont que des exemples. Ces touches ne suppriment, ne téléversent, ne déplacent et ne retouchent jamais une photo. Renommez-les selon votre travail, par exemple À imprimer ou Retouche terminée.

### Enregistrement local

Les étiquettes attribuées, leurs noms et couleurs ainsi que les rapports sont conservés dans la base SQLite locale ~/Library/Application Support/org.openimageviewer.ImageViewer/PhotoMarks.sqlite. Ils reviennent au prochain lancement, restent distincts des métadonnées EXIF et ne sont synchronisés ni par XMP ni par une photothèque dans le cloud.

### Bon à savoir

- Les touches d’étiquettes priment sur les actions ordinaires pendant le marquage. Ainsi, 1 et F attribuent des étiquettes au lieu d’activer Taille réelle ou le mode concentration. Quittez le marquage pour réutiliser ces raccourcis ordinaires.

[Retour en haut](#top)

---

<a name="tag-editor"></a>

## 6. Définir les noms, couleurs et règles de suivi des étiquettes

Donnez aux douze touches des noms adaptés à votre travail. Les affectations sont communes aux dossiers ; le suivi et ses rapports conservent les étiquettes lors des changements de fichiers reconnus.

![L’éditeur commun des noms et couleurs d’étiquettes.](figures/tag-editor.png)

**Écran 05.** L’éditeur commun des noms et couleurs d’étiquettes.

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

**Écran 06.** Vue carte avec ses zones de sélection et le résumé des photos correspondantes.

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

Ouvrir la sélection dans la Visionneuse ou Tout voir conserve la restriction géographique et les filtres de nom, format et étiquettes. Dans l’aperçu d’un lieu, Cette photo traite l’image courante et Toutes les photos de ce lieu traite le groupe. Effacer la zone de carte retrouve la liste sans restriction géographique, y compris les photos sans GPS ; ouvrir une photo hors zone supprime cette restriction.

### Chargement et état mémorisé

Le fond de carte nécessite une connexion Internet. Les photos sans GPS ne figurent pas parmi les vignettes de la carte. Lire les positions peut prendre du temps dans une grande collection. Les zones sont restaurées avec la dernière session ; ouvrir un nouveau dossier efface les zones sélectionnées précédemment.

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

**Écran 07.** Le panneau de retouche à côté de l’aperçu de l’image actuelle.

1. **Commandes de retouche** — Recadrez, tournez, retournez et réglez les tons, les couleurs et les détails.
2. **Aperçu de l’image** — Examinez le résultat actuel ; utilisez Taille réelle pour les réglages de détail.
3. **Exporter — en bas du panneau** — Faites défiler le panneau de retouche vers le bas ou appuyez sur ⌘E pour enregistrer une copie avant de fermer l’application.

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

**Écran 08.** La fenêtre de conversion par lot, ses réglages de taille et la prévisualisation des fichiers.

1. **Format et qualité** — Choisissez l’encodage de sortie et sa qualité lorsque le format le permet.
2. **Réduction proportionnelle** — Conservez la taille ou fixez le côté le plus long ou un pourcentage ; Réduire le poids propose JPEG, 1920 pixels et 75 %.
3. **Destination et aperçu** — Choisissez le dossier, vérifiez les noms puis convertissez. Les originaux sont conservés.

### Marche à suivre

1. Sélectionnez les images avec ⌘ + clic, ⇧ + clic ou ⌘A. Dans Tout voir, vous pouvez aussi tracer un rectangle de sélection. Utilisez le menu de sélection, le menu contextuel ou Image ; sur la carte, utilisez Photos de la zone, Cette photo ou Toutes les photos de ce lieu.
2. Dans Renommer par lot…, conservez ou remplacez le nom, ou utilisez la recherche et le remplacement. Avec Utiliser un nom de classement, choisissez explicitement une étiquette : seuls les fichiers sélectionnés qui la portent seront renommés. Vérifiez la liste avant/après.
3. Ouvrez Convertir, redimensionner et compresser…, choisissez le format, la qualité et Taille de l’image, puis le dossier. Côté le plus long ou Pourcentage réduit proportionnellement après les retouches et le recadrage, sans agrandir les petites images. Réduire le poids règle JPEG, 1920 pixels et 75 % de qualité.

### Numérotation et validité des noms

Le mode classement crée Envoi01, Envoi02… sans séparateur. De 1 à 99 fichiers concernés, il utilise deux chiffres ; dès 100, trois chiffres à partir de 001, puis davantage si nécessaire. Il suit l’ordre de la liste et conserve l’extension. Les autres modes permettent de régler début, incrément, chiffres et séparateur. Des noms invalides ou en double empêchent le renommage. Les images ZIP ne peuvent pas être renommées sur place.

### Extension, format et poids

Renommer une extension normalise les majuscules et variantes du même format, comme .jpg/.jpeg ou .tif/.tiff. Passer de HEIC à JPEG exige la conversion pour modifier l’encodage. La réduction du poids dépend du contenu, du format, de la qualité et des dimensions ; elle ne vise pas un nombre exact d’octets et peut produire un fichier plus lourd.

### Copies converties et partage macOS

La conversion applique les retouches actuelles en préservant les originaux et leurs étiquettes ; les copies sont distinctes. Un nom déjà utilisé reçoit un numéro. Les animations et images multipages ne conservent que leur première image. Un arrêt garde les fichiers terminés et affiche les nombres enregistrés, en échec et non traités. Partager les fichiers… partage les fichiers source, sans appliquer les retouches d’aperçu. Pour partager les copies retouchées ou réduites, utilisez Partager les fichiers terminés… après conversion, même si le lot est partiellement terminé.

### Bon à savoir

- Filtrez par recherche, format, étiquettes ou carte avant de tout sélectionner. Vérifiez le nombre et la liste avant tout renommage des originaux. Les services de partage proposés, tels qu’AirDrop, dépendent de macOS et de sa configuration.

[Retour en haut](#top)

---

<a name="quality"></a>

## 11. Comprendre l’agrandissement IA, le HDR et le chargement

Zoom haute qualité change l’interpolation d’affichage. Agrandissement IA crée une image plus grande à enregistrer. La sortie HDR est une préférence d’affichage, pas une preuve que la photo est HDR.

### Marche à suivre

1. Pour un affichage plus lisse, activez Zoom haute qualité. Sa comparaison côte à côte ou de haut en bas montre la même photo avec zoom et déplacement liés ; Esc ferme cette comparaison.
2. Pour créer une image 2×, sélectionnez une photo, ouvrez Agrandissement IA… et cliquez sur Lancer l’agrandissement IA. Vérifiez Comparer à l’original et Pixels réels, puis Enregistrer une copie PNG….
3. Utilisez les commandes de sortie HDR activée/désactivée pour autoriser ou non l’affichage étendu. Dans Réglages → Général → Chargement des images, choisissez Prioritaire, Confortable, Normal ou Lent selon votre usage.

### Résultat et limites de l’IA

Le modèle fourni fonctionne localement avec Core ML : les photos ne sont pas téléversées et aucun modèle n’est téléchargé pendant l’utilisation. La largeur et la hauteur sont doublées. Le résultat est un PNG sRGB SDR 8 bits, avec une transparence interpolée séparément. Une animation utilise sa première image et les retouches de la visionneuse sont exclues. La sortie est limitée à 64 millions de pixels au maximum, avec une limite potentiellement inférieure sur les Mac peu dotés en mémoire. Enregistrez avant de fermer ; les détails IA sont une estimation.

### Formats et performances

Les formats lisibles et inscriptibles dépendent du macOS exécuté. L’application ajoute le décodage QOI et des variantes PCX courantes, ainsi qu’une solution de repli SVG/SVGZ. BPG et .clip ne sont pas inclus. Confortable est le mode de chargement par défaut. Tous les modes ralentissent en cas de pression mémoire, de chaleur, de mode économie d’énergie, d’autres applications actives ou de stockage plus lent.

### Bon à savoir

- Pendant une navigation rapide, un petit aperçu ou la photo précédente peut rester visible jusqu’à ce que l’image finale soit prête. L’IA 4×, la sortie HDR par IA et l’agrandissement IA par lot ne sont pas proposés.

[Retour en haut](#top)

---

<a name="slideshow"></a>

## 12. Lire un album photo ou définir le fond d’écran

Album photo fait défiler automatiquement la liste actuelle, une image à la fois en mode concentration. Le fond d’écran utilise une copie distincte préparée pour les écrans choisis.

### Marche à suivre

1. Ouvrez une liste contenant au moins deux photos. Choisissez Navigation → Album photo → Lire l’album photo ou appuyez sur ⌃⌥P.
2. Utilisez les commandes de lecture pour mettre en pause. Choisissez un intervalle de 1 à 300 secondes et la répétition, avec la commande de durée ou dans Réglages → Général → Album photo.
3. Pour définir un fond d’écran, revenez à la visionneuse normale et choisissez Image → Utiliser l’image actuelle comme fond d’écran… ou appuyez sur ⌃⌥W. Choisissez l’écran actuel ou tous les écrans connectés, Remplir l’écran ou Afficher toute la photo, et l’application éventuelle des réglages actuels ; puis appliquez.

### Déroulement de la lecture

L’intervalle par défaut est de cinq secondes avec répétition. Le décompte commence après l’affichage d’un aperçu ou de l’image : le chargement ne réduit donc pas le temps de visionnage. Une navigation manuelle ou un changement d’intervalle relance le décompte. Sans répétition, la lecture s’arrête sur la dernière image.

### Pauses automatiques

La lecture se met en pause en quittant le mode concentration, en changeant d’application, lors de la mise en veille ou au début d’une opération sur les fichiers. L’écran reste éveillé uniquement pendant la lecture. Au prochain lancement, les réglages sont restaurés mais la lecture ne démarre jamais automatiquement.

### Copies de fond d’écran

L’application crée un PNG sans modifier la source. Elle prend la première image des animations et prépare le HDR en SDR. Les copies excluent EXIF/GPS, sont dimensionnées pour l’écran jusqu’à 8192 pixels et restent dans le dossier Application Support/Wallpapers de l’application. Les autres espaces de bureau suivent le comportement de macOS. Les anciennes copies ne sont pas supprimées automatiquement, car un autre espace peut encore les utiliser.

### Bon à savoir

- Si la lecture est indisponible, vérifiez que la liste filtrée contient au moins deux photos et que le marquage, la Comparaison d’images ou une autre opération ne sont pas actifs.

[Retour en haut](#top)

---

<a name="settings"></a>

## 13. Adapter l’application à vos habitudes

Les réglages réunissent l’affichage quotidien, les raccourcis personnalisés, les étiquettes et les associations de fichiers. De nombreux choix reviennent automatiquement au lancement suivant.

![Les réglages regroupent les principales préférences dans quatre onglets.](figures/settings.png)

**Écran 09.** Les réglages regroupent les principales préférences dans quatre onglets.

1. **Onglets des réglages** — Général, Raccourcis, Étiquettes photo et Associations de fichiers correspondent chacun à une tâche.
2. **Préférences d’affichage** — Réglez l’écran, les vignettes, les noms de fichiers, la navigation et le chargement.
3. **Explications intégrées** — Lisez le texte sous une commande ou survolez-la pour connaître son fonctionnement.

### Marche à suivre

1. Ouvrez 알맹Re → Réglages…. Dans Général, choisissez la sortie HDR/EDR, la position des vignettes, la taille des noms de fichiers, le zoom haute qualité, l’affichage de l’arborescence et le retour au début après la dernière image.
2. Dans Étiquettes photo, enregistrez les noms et couleurs communs ; dans Raccourcis, choisissez les touches et combinaisons de modificateurs. Survolez les commandes pour lire leurs explications.
3. Pour que le Finder ouvre certains formats avec cette application, placez 알맹Re.app à un emplacement stable, comme Applications, ouvrez Associations de fichiers, cochez seulement les groupes de formats souhaités et appliquez.

### Langue

L’interface suit la langue attribuée à l’application par macOS. Changez-la dans Réglages Système → Général → Langue et région → Applications. L’application prend en charge le coréen, l’anglais, le chinois simplifié, le japonais, le français, l’espagnol, l’arabe et le vietnamien ; cette collection de guides couvre sept langues.

### Préférences mémorisées

La taille des vignettes, le zoom haute qualité, les noms de fichiers, le chargement, les favoris, les étiquettes et les raccourcis sont conservés. La dernière collection et la position d’affichage peuvent être restaurées si les fichiers restent accessibles. La comparaison de qualité du zoom est désactivée au prochain lancement. Retouches visuelles et résultats IA doivent être exportés séparément.

### Associations de fichiers

Seuls les groupes de formats cochés sont modifiés. macOS peut demander confirmation. Déplacer l’application ou conserver d’anciennes copies peut amener le Finder à ouvrir la mauvaise version ; réappliquez les associations depuis celle que vous voulez utiliser.

### Bon à savoir

- Général répertorie aussi les formats natifs disponibles sur votre Mac et propose Vider le cache d’images. Choisissez un mode de chargement plus lent pour réduire le travail en arrière-plan pendant l’utilisation d’autres applications.

[Retour en haut](#top)

---

<a name="shortcuts"></a>

## 14. Raccourcis et dépannage rapide

Le tableau suivant indique les touches d’action par défaut et les touches contextuelles fixes. ⌘ signifie Commande, ⌥ Option, ⌃ Contrôle et ⇧ Maj.

![L’onglet Raccourcis présente les actions configurables et les conflits.](figures/shortcuts.png)

**Écran 10.** L’onglet Raccourcis présente les actions configurables et les conflits.

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
| ← / → | Image ou page précédente / suivante | Configurable. La Visionneuse avance par le nombre d’images par vue ; la comparaison suit A seul / Les deux / B seul. |
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
| 1 2 3 4 · Q W E R · A S D F | Ajouter/retirer les douze étiquettes photo | Positions physiques fixes ; mode marquage uniquement. Noms et couleurs modifiables ; aucune touche ne supprime ni ne téléverse de fichier. |
| ← / ↑ · → / ↓ | Photo précédente / suivante pendant le marquage | Navigation fixe du mode marquage ; une photo à la fois. |
| ⌘A | Sélectionner toutes les images de la liste actuelle | Raccourci fixe de sélection hors Comparaison d’images ; les champs de texte conservent leur sélection de texte habituelle. |
| Esc | Annuler le geste ou quitter le mode actif | Fixe. Quitte le marquage, la comparaison, la comparaison de qualité du zoom ou le mode concentration ; la Visionneuse normale revient à Tout voir. Annule aussi les gestes de sélection de zone. |

[Retour en haut](#top)
