#lang racket/base
(require racket/class
         racket/string
         ffi/unsafe/atomic
         "syntax.rkt"
         "../unsafe/pango.rkt"
         "../unsafe/cairo.rkt"
         "font-syms.rkt"
         "font-dir.rkt"
         "local.rkt"
         "xp.rkt"
         "lock.rkt")

(provide font%
         font-list% the-font-list current-font-list
         make-font
         family-symbol? style-symbol? smoothing-symbol? hinting-symbol?
         get-face-list
         (protect-out substitute-fonts?
                      install-alternate-face
                      get-pango-attrs
                      font->pango-attrs ;; redundant with `get-pango-attrs`,
                                        ;; only exists for backwards compatibility
                      font->hinting
                      install-attributes!))

(define-local-member-name 
  get-pango-attrs
  s-hinting)

;; attrs-key => PangoAttrList
(define attrs-cache (make-ephemeron-hash))
(struct attrs-key (underlined? feature-settings) #:transparent)

(define (make-pango-attrs key #:no-fallback? [no-fallback? (eq? 'macosx (system-type))])
  (define l (pango_attr_list_new))
  (when no-fallback?
    (pango_attr_list_insert l (pango_attr_fallback_new #f)))
  (when (attrs-key-underlined? key)
    (pango_attr_list_insert l (pango_attr_underline_new
                               PANGO_UNDERLINE_SINGLE)))
  (unless (hash-empty? (attrs-key-feature-settings key))
    (define css-features
      (for/list ([(tag val) (in-immutable-hash (attrs-key-feature-settings key))])
        (format "\"~a\" ~a" tag val)))
    (pango_attr_list_insert l (pango_attr_font_features_new
                               (string-join css-features ","))))
  l)

(define default-attrs-key (attrs-key #f (hash)))
(define default-attrs (make-pango-attrs default-attrs-key))
(hash-set! attrs-cache default-attrs-key default-attrs)
(define xp-no-fallback-attrs (and xp? (make-pango-attrs default-attrs-key #:no-fallback? #t)))

(define (install-attributes! layout attrs)
  (pango_layout_set_attributes layout (or attrs default-attrs)))

(define-local-member-name s-set-table-key)

(define font-descs (make-weak-hash))
(define ps-font-descs (make-weak-hash))
(define keys (make-weak-hash))

(define substitute-fonts? (memq (system-type) '(macosx windows)))
(define substitute-mapping (make-hasheq))

(define (install-alternate-face ch layout font desc attrs context)
  (or
   (for/or ([face (in-list 
                   (let ([v (hash-ref substitute-mapping (char->integer ch) #f)])
                     (cond
                      [(string? v) 
                       ;; found previously
                       (list v)]
                      [v 
                       ;; failed to find previously
                       null]
                      [else
                       ;; Hack: prefer a particular font for Mac OS
                       (cons "Arial Unicode MS" (get-face-list))])))])
     (let ([desc (send (make-object font%
                                    (send font get-point-size)
                                    face
                                    (send font get-family)
                                    (send font get-style)
                                    (send font get-weight)
                                    (send font get-underlined)
                                    (send font get-smoothing)
                                    (send font get-size-in-pixels))
                       get-pango)])
       (and desc
            (let ([attrs (send font get-pango-attrs)])
              (pango_layout_set_font_description layout desc)
              (install-attributes! layout attrs)
              (and (zero? (pango_layout_get_unknown_glyphs_count layout))
                   (begin
                     (hash-set! substitute-mapping (char->integer ch) face)
                     #t))))))
   (begin
     (hash-set! substitute-mapping (char->integer ch) #t)
     ;; put old desc & attrs back
     (pango_layout_set_font_description layout desc)
     (install-attributes! layout attrs))))

(define (has-screen-glyph? c font desc for-label?)
  (let* ([s (cairo_image_surface_create CAIRO_FORMAT_ARGB32 1 1)]
         [cr (cairo_create s)]
         [context (pango_cairo_create_context cr)]
         [layout (pango_layout_new context)]
	 ;; Under Windows XP, there's no font 
	 ;; fallback/substitution in control labels:
	 [no-subs? (and xp? for-label?)])
    (pango_layout_set_font_description layout desc)
    (pango_layout_set_text layout (string c))
    (when no-subs?
      (pango_layout_set_attributes layout xp-no-fallback-attrs))
    (pango_cairo_update_layout cr layout)
    (begin0
     (or (zero? (pango_layout_get_unknown_glyphs_count layout))
         (and substitute-fonts?
	      (not no-subs?)
              (install-alternate-face c layout font desc #f context)
              (zero? (pango_layout_get_unknown_glyphs_count layout))))
     (g_object_unref layout)
     (g_object_unref context)
     (cairo_destroy cr)
     (cairo_surface_destroy s))))

(define dpi-scale
  ;; Hard-wire 96dpi for Windows and Linux, but 72 dpi for Mac OS
  ;; (based on historical defaults on those platforms).
  ;; If the actual DPI for the screen is different, we'll handle
  ;; that by scaling to and from the screen.
  (if (eq? 'macosx (system-type))
      1.0
      (/ 96.0 72.0)))

(defclass font% object%

  (define table-key #f)
  (define/public (s-set-table-key k) (set! table-key k))

  (define cached-desc #f)
  (define ps-cached-desc #f)
  
  (define/public (get-pango)
    (create-desc #f 
                 cached-desc
                 font-descs
                 (lambda (d) (set! cached-desc d))))

  (define/public (get-ps-pango)
    (create-desc #t
                 ps-cached-desc
                 ps-font-descs
                 (lambda (d) (set! ps-cached-desc d))))

  (define/private (create-desc ps? cached-desc font-descs install!)
    (or cached-desc
        (let ([desc-e (atomically (hash-ref font-descs key #f))])
          (and desc-e
               (let ([desc (ephemeron-value desc-e)])
                 (install! desc)
                 desc)))
        (let* ([desc-str (if ps?
                             (send the-font-name-directory
                                   get-post-script-name
                                   id
                                   weight
                                   style)
                             (send the-font-name-directory
                                   get-screen-name
                                   id
                                   weight
                                   style))]
               [desc (if (regexp-match #rx"," desc-str)
                         ;; comma -> a font description
                         (pango_font_description_from_string desc-str)
                         ;; no comma -> a font family
                         (let ([desc (pango_font_description_new)])
                           (pango_font_description_set_family desc desc-str)
                           desc))])
          (unless (eq? style 'normal)
            (pango_font_description_set_style desc (case style
                                                     [(normal) PANGO_STYLE_NORMAL]
                                                     [(italic) PANGO_STYLE_ITALIC]
                                                     [(slant) PANGO_STYLE_OBLIQUE])))
          (unless (or (eq? weight 'normal) (eqv? weight 300))
            (pango_font_description_set_weight desc (case weight
                                                      [(thin) PANGO_WEIGHT_THIN]
                                                      [(ultralight) PANGO_WEIGHT_ULTRALIGHT]
                                                      [(light) PANGO_WEIGHT_LIGHT]
                                                      [(semilight) PANGO_WEIGHT_SEMILIGHT]
                                                      [(book) PANGO_WEIGHT_BOOK]
                                                      [(normal) PANGO_WEIGHT_NORMAL]
                                                      [(medium) PANGO_WEIGHT_MEDIUM]
                                                      [(semibold) PANGO_WEIGHT_SEMIBOLD]
                                                      [(bold) PANGO_WEIGHT_BOLD]
                                                      [(ultrabold) PANGO_WEIGHT_ULTRABOLD]
                                                      [(heavy) PANGO_WEIGHT_HEAVY]
                                                      [(ultraheavy) PANGO_WEIGHT_ULTRAHEAVY]
                                                      [else weight])))
          (pango_font_description_set_absolute_size desc (* size-in-pixels PANGO_SCALE))
          (install! desc)
          (atomically (hash-set! font-descs key (make-ephemeron key desc)))
          desc)))

  (define pango-attrs #f)
  (define/public (get-pango-attrs)
    (cond
      [pango-attrs => values]
      [(atomically (hash-ref-key attrs-cache pango-attrs-key #f))
       => (lambda (cache-key)
            (set! pango-attrs-key cache-key)
            (set! pango-attrs (atomically (hash-ref attrs-cache cache-key)))
            pango-attrs)]
      [else
       (set! pango-attrs (make-pango-attrs pango-attrs-key))
       (atomically (hash-set! attrs-cache pango-attrs-key pango-attrs))
       pango-attrs]))

  (define face #f)
  (def/public (get-face) face)

  (define family 'default)
  (def/public (get-family) family)

  (define size 12.0)
  (define size-in-points size)
  (define size-in-pixels (* size-in-points dpi-scale))
  (def/public (get-point-size) (max 1 (inexact->exact (round size))))
  
  (define/public (get-size [in-pixels? size-in-pixels?])
    (if in-pixels? size-in-pixels size-in-points))

  (define size-in-pixels? #f)
  (def/public (get-size-in-pixels) size-in-pixels?)

  (define smoothing 'default)
  (def/public (get-smoothing) smoothing)
  
  (field [s-hinting 'aligned])
  (def/public (get-hinting) s-hinting)
  
  (define style 'normal)
  (def/public (get-style) style)

  (define underlined? #f)
  (def/public (get-underlined) underlined?)

  (define feature-settings (hash))
  (def/public (get-feature-settings) feature-settings)

  (define weight 'normal)
  (def/public (get-weight) weight)

  (def/public (get-font-id) id)
  (def/public (get-font-key) key)

  (define/public (screen-glyph-exists? c [for-label? #f])
    (has-screen-glyph? c this (get-pango) for-label?))

  (init-rest args)
  (super-new)
  (case-args 
   args
   [() (void)]
   [([(real-in 0.0 1024.0) _size]
     [family-symbol? _family]
     [style-symbol? [_style 'normal]]
     [font-weight/c [_weight 'normal]]
     [any? [_underlined? #f]]
     [smoothing-symbol? [_smoothing 'default]]
     [any? [_size-in-pixels? #f]]
     [hinting-symbol? [_hinting 'aligned]]
     [font-feature-settings/c [_feature-settings (hash)]])
    (set! size (exact->inexact _size))
    (set! family _family)
    (set! style _style)
    (set! weight _weight)
    (set! underlined? (and _underlined? #t))
    (set! smoothing _smoothing)
    (set! size-in-pixels? (and _size-in-pixels? #t))
    (set! s-hinting _hinting)
    (set! feature-settings _feature-settings)]
   [([(real-in 0.0 1024.0) _size]
     [(make-or-false string?) _face]
     [family-symbol? _family]
     [style-symbol? [_style 'normal]]
     [font-weight/c [_weight 'normal]]
     [any? [_underlined? #f]]
     [smoothing-symbol? [_smoothing 'default]]
     [any? [_size-in-pixels? #f]]
     [hinting-symbol? [_hinting 'aligned]]
     [font-feature-settings/c [_feature-settings (hash)]])
    (set! size (exact->inexact _size))
    (set! face (and _face (string->immutable-string _face)))
    (set! family _family)
    (set! style _style)
    (set! weight _weight)
    (set! underlined? (and _underlined? #t))
    (set! smoothing _smoothing)
    (set! size-in-pixels? (and _size-in-pixels? #t))
    (set! s-hinting _hinting)
    (set! feature-settings _feature-settings)]
   (init-name 'font%))

  (cond
    [size-in-pixels?
     (set! size-in-pixels size)
     (set! size-in-points (/ size dpi-scale))]
    [else
     (set! size-in-pixels (* size dpi-scale))
     (set! size-in-points size)])

  (define id 
    (if face
        (send the-font-name-directory find-or-create-font-id face family)
        (send the-font-name-directory find-family-default-font-id family)))
  (define key
    (let ([key (vector id size style weight underlined? smoothing size-in-pixels? s-hinting)])
      (let ([old-key (atomically (hash-ref keys key #f))])
        (if old-key
            (weak-box-value old-key)
            (begin
              (atomically (hash-set! keys key (make-weak-box key)))
              key)))))
  (define pango-attrs-key (attrs-key underlined? feature-settings)))

(define (font->pango-attrs v) (send v get-pango-attrs))
(define font->hinting (class-field-accessor font% s-hinting))

;; ----------------------------------------

(defclass font-list% object%
  (define fonts (make-weak-hash))
  (super-new)
  (define/public (find-or-create-font . args)
    (let ([key
           (case-args 
            args
            [([(real-in 0.0 1024.0) size]
              [family-symbol? family]
              [style-symbol? [style 'normal]]
              [font-weight/c [weight 'normal]]
              [any? [underlined? #f]]
              [smoothing-symbol? [smoothing 'default]]
              [any? [size-in-pixels? #f]]
              [hinting-symbol? [hinting 'aligned]]
              [font-feature-settings/c [feature-settings (hash)]])
             (vector (exact->inexact size) family style weight underlined? smoothing
                     size-in-pixels? hinting feature-settings)]
            [([(real-in 0.0 1024.0) size]
              [(make-or-false string?) face]
              [family-symbol? family]
              [style-symbol? [style 'normal]]
              [font-weight/c [weight 'normal]]
              [any? [underlined? #f]]
              [smoothing-symbol? [smoothing 'default]]
              [any? [size-in-pixels? #f]]
              [hinting-symbol? [hinting 'aligned]]
              [font-feature-settings/c [feature-settings (hash)]])
             (vector (exact->inexact size) (and face (string->immutable-string face)) family
                     style weight underlined? smoothing size-in-pixels? hinting feature-settings)]
            (method-name 'find-or-create-font 'font-list%))])
      (atomically
       (let ([e (hash-ref fonts key #f)])
         (or (and e
                  (ephemeron-value e))
             (let* ([f (apply make-object font% (vector->list key))]
                    [e (make-ephemeron key f)])
               (send f s-set-table-key key)
               (hash-set! fonts key e)
               f)))))))

(define the-font-list (new font-list%))

(define (get-face-list [mode 'all] #:all-variants? [all-variants? #f])
  (unless (or (eq? mode 'all) (eq? mode 'mono))
    (raise-type-error get-face-list "'all or 'mono" mode))
  (sort
   (apply
    append
    (for/list ([fam (in-list
                     (let ([fams (pango_font_map_list_families
                                  (pango_cairo_font_map_get_default))])
                       (if (eq? mode 'mono)
                           (filter pango_font_family_is_monospace fams)
                           fams)))])
      (if (not all-variants?)
          (list (pango_font_family_get_name fam))
          (for/list ([face (in-list (pango_font_family_list_faces fam))])
            (define family-name (pango_font_family_get_name fam))
            (define full-name (pango_font_description_to_string
                               (pango_font_face_describe face)))
            (define len (string-length family-name))
            ;; Normally, the full description will extend the family name:
            (cond
             [(and ((string-length full-name) . > . (+ len 1))
                   (string=? (substring full-name 0 len) family-name)
                   (char=? #\space (string-ref full-name len)))
              (string-append family-name "," (substring full-name len))]
             [#f
              ;; If the full description doesn't extend the name, then we
              ;; could show more information by adding the font's declared
              ;; face string. But that may not be parseable by Pango, so
              ;; we don't return this currently. Maybe one day add an option
              ;; to expose this string.
              (string-append family-name ", " (pango_font_face_get_face_name face))]
             [else
              ;; In this case, we can't say more than just the family name,
              ;; even though that may produce duplicates (but usually won't)
              family-name])))))
   string<?))

(define current-font-list (make-parameter #f))

(define (make-font #:size [size 12.0]
                   #:face [face #f]
                   #:family [family 'default]
                   #:style [style 'normal]
                   #:weight [weight 'normal]
                   #:underlined? [underlined? #f]
                   #:smoothing [smoothing 'default]
                   #:size-in-pixels? [size-in-pixels? #f]
                   #:hinting [hinting 'aligned]
                   #:feature-settings [feature-settings (hash)]
                   #:font-list [font-list (current-font-list)])
  (unless (and (real? size) (<= 0.0 size 1024.0)) (raise-type-error 'make-font "real number in [0.0, 1024.0]" size))
  (unless (or (not face) (string? face)) (raise-type-error 'make-font "string or #f" face))
  (unless (family-symbol? family) (raise-type-error 'make-font "family-symbol" family))
  (unless (style-symbol? style) (raise-type-error 'make-font "style-symbol" style))
  (unless (font-weight/c weight) (raise-argument-error 'make-font "font-weight/c" weight))
  (unless (smoothing-symbol? smoothing) (raise-type-error 'make-font "smoothing-symbol" smoothing))
  (unless (hinting-symbol? hinting) (raise-type-error 'make-font "hinting-symbol" hinting))
  (unless (or (not font-list) (is-a? font-list font-list%))
    (raise-argument-error 'make-font "(or/c (is-a?/c font-list%) #f)" font-list))
  (if font-list
      (send font-list find-or-create-font size face family style weight underlined? smoothing size-in-pixels? hinting feature-settings)
      (make-object font% size face family style weight underlined? smoothing size-in-pixels? hinting feature-settings)))
