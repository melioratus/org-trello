;;; org-trello-proxy.el --- Proxy namespace (in charge of receiving actions to transmit to the consumer).
;;; Commentary:
;;; Code:

(require 'org-trello-log)
(require 'org-trello-setup)
(require 'org-trello-query)
(require 'org-trello-api)
(require 'org-trello-data)
(require 'org-trello-hash)
(require 'org-trello-buffer)
(require 'org-trello-cbx)
(require 'org-trello-action)

(defun orgtrello-proxy/--compute-trello-query (query-map-data)
  "Build a trello query from the content of QUERY-MAP-DATA."
  (orgtrello-api/make-query (orgtrello-data/entity-method query-map-data) (orgtrello-data/entity-uri query-map-data) (orgtrello-data/entity-params query-map-data)))

(defun orgtrello-proxy/sync-from (query-map-data &optional sync)
  "Deal with request QUERY-MAP-DATA from trello.
The query can be synchronous depending on SYNC variable."
  (orgtrello-log/msg *OT/TRACE* "Proxy - Request received. Transmitting...")
  (let* ((position (orgtrello-data/entity-position query-map-data))          ;; position is mandatory
         (buffer-name (orgtrello-data/entity-buffername query-map-data))     ;; buffer-name is mandatory
         (standard-callback (orgtrello-data/entity-callback query-map-data)) ;; there is the possibility to transmit the callback from the client to the proxy
         (standard-callback-fn (when standard-callback standard-callback))   ;; the callback is passed as a string, we want it as a function when defined
         (query-map (orgtrello-proxy/--compute-trello-query query-map-data)) ;; extracting the query
         (name (orgtrello-data/entity-name query-map-data)))                 ;; extracting the name of the entity (optional)
    (orgtrello-query/http-trello query-map sync (when standard-callback-fn (funcall standard-callback-fn buffer-name position name)))))

(defun orgtrello-proxy/--update-buffer-to-save (buffer-name buffers-to-save)
  "Add the BUFFER-NAME to the list of BUFFERS-TO-SAVE if not already present."
  (if (member buffer-name buffers-to-save)
      buffers-to-save
    (cons buffer-name buffers-to-save)))

(defvar *ORGTRELLO/LIST-BUFFERS-TO-SAVE* nil "A simple flag to order the saving of buffer when needed.")

(defun orgtrello-proxy/update-buffer-to-save! (buffer-name)
  "Side-effect - Mutate the *ORGTRELLO/LIST-BUFFERS-TO-SAVE* by adding BUFFER-NAME to it if not already present."
  (setq *ORGTRELLO/LIST-BUFFERS-TO-SAVE* (orgtrello-proxy/--update-buffer-to-save buffer-name *ORGTRELLO/LIST-BUFFERS-TO-SAVE*)))

(defun orgtrello-proxy/--cleanup-and-save-buffer-metadata (level buffer-name)
  "To cleanup metadata (LEVEL, BUFFER-NAME) after all the actions are done!"
  (orgtrello-proxy/update-buffer-to-save! buffer-name)) ;; register the buffer for later saving

(defun orgtrello-proxy/batch-save (buffers)
  "Save sequentially a list of BUFFERS."
  (-each buffers (lambda (buffername)
                   (with-current-buffer buffername
                     (call-interactively 'save-buffer)))))

(defun orgtrello-proxy/batch-save! ()
  "Save sequentially the org-trello list of modified buffers."
  (setq *ORGTRELLO/LIST-BUFFERS-TO-SAVE* (orgtrello-proxy/batch-save *ORGTRELLO/LIST-BUFFERS-TO-SAVE*)))

(defun orgtrello-proxy/--getting-back-to-headline (data)
  "Trying another approach to getting back to header computing the normal form of the entry DATA in the buffer."
  (orgtrello-proxy/--getting-back-to-marker (orgtrello-buffer/--compute-entity-to-org-entry data)))

(defun orgtrello-proxy/--compute-pattern-search-from-marker (marker)
  "Given a MARKER, compute the pattern to look for in the file."
  marker)

(defun orgtrello-proxy/--getting-back-to-marker (marker)
  "Given a MARKER, getting back to marker function.
Move the cursor position."
  (goto-char (point-min))
  (re-search-forward (orgtrello-proxy/--compute-pattern-search-from-marker marker) nil t))

(defun orgtrello-proxy/--get-back-to-marker (marker data)
  "Getting back to MARKER if possible, otherwise return to the DATA headline.
Move the cursor position."
  (-if-let (goto-ok (orgtrello-proxy/--getting-back-to-marker marker))
      goto-ok
    (orgtrello-proxy/--getting-back-to-headline data)))

(defun orgtrello-proxy/--standard-post-or-put-success-callback (entity-to-sync)
  "Return a callback function able to deal with the update query of ENTITY-TO-SYNC the buffer at a given position."
  (lexical-let ((entry-position    (orgtrello-data/entity-position entity-to-sync))
                (entry-buffer-name (orgtrello-data/entity-buffername entity-to-sync))
                (level             (orgtrello-data/entity-level entity-to-sync))
                (marker-id         (orgtrello-data/entity-id-or-marker entity-to-sync))
                (entity-name       (orgtrello-data/entity-name entity-to-sync)))
    (function* (lambda (&key data &allow-other-keys)
                 (orgtrello-action/safe-wrap
                  (let ((entry-new-id (orgtrello-data/entity-id data)))
                    (with-current-buffer entry-buffer-name
                      ;; will update via tag the trello id of the new persisted data (if needed)
                      (save-excursion
                        ;; get back to the buffer and update the id if need be
                        (-when-let (str-msg (when (orgtrello-proxy/--get-back-to-marker marker-id data)
                                              (-if-let (entry-id (when (orgtrello-data/id-p marker-id) marker-id)) ;; Already present, we do nothing on the buffer
                                                  (format "Entity '%s' with id '%s' synced!" entity-name entry-id)
                                                (let ((entry-name (orgtrello-data/entity-name data))) ;; not present, this was just created, we add a simple property
                                                  (orgtrello-buffer/set-property *ORGTRELLO/ID* entry-new-id)
                                                  (format "Newly entity '%s' with id '%s' synced!" entry-name entry-new-id)))))
                          (orgtrello-log/msg *OT/INFO* str-msg)))))
                  (orgtrello-proxy/--cleanup-and-save-buffer-metadata level entry-buffer-name))))))

(defun orgtrello-proxy/--dispatch-action (action)
  "Compute the action function depending on the ACTION (sync, delete) to execute."
  (cond ((string= *ORGTRELLO/ACTION-DELETE* action) 'orgtrello-proxy/--delete)
        ((string= *ORGTRELLO/ACTION-SYNC*   action) 'orgtrello-proxy/--sync-entity)))

(defun orgtrello-proxy/--cleanup-meta (entity-full-metadata)
  "Clean the ENTITY-FULL-METADATA meta up."
  (unless (-> entity-full-metadata
            orgtrello-data/current
            orgtrello-data/entity-id)
    (orgtrello-cbx/org-delete-property *ORGTRELLO/ID*)))

(defun orgtrello-proxy/--retrieve-state-of-card (card-meta)
  "Given a CARD-META, retrieve its state depending on its :keyword metadata.
If empty or no keyword then, its equivalence is *ORGTRELLO/TODO*, otherwise, return its current state."
  (-if-let (card-kwd (orgtrello-data/entity-keyword card-meta *ORGTRELLO/TODO*)) card-kwd *ORGTRELLO/TODO*))

(defun orgtrello-proxy/--checks-before-sync-card (card-meta)
  "Given the CARD-META, check is done before synchronizing the cards."
  (if (orgtrello-data/entity-name card-meta) :ok *ORGTRELLO/ERROR-SYNC-CARD-MISSING-NAME*))

(defun orgtrello-proxy/--tags-to-labels (tags)
  "Transform org TAGS string to csv labels."
  (when tags
    (let* ((s (s-split ":" tags))
           (ns (if (string= "" (car s)) (cdr s) s)))
      (s-join "," ns))))

(defun orgtrello-proxy/--card (card-meta &optional parent-meta grandparent-meta)
  "Deal with create/update CARD-META query build.
PARENT-META and GRANDPARENT-META are indispensable.
If the checks are ko, the error message is returned."
  (let ((checks-ok-or-error-message (orgtrello-proxy/--checks-before-sync-card card-meta)))
    ;; name is mandatory
    (if (equal :ok checks-ok-or-error-message)
        ;; parent and grandparent are useless here
        (let* ((card-kwd                (orgtrello-proxy/--retrieve-state-of-card card-meta))
               (list-id                 (orgtrello-buffer/org-file-get-property! card-kwd))
               (card-id                 (orgtrello-data/entity-id          card-meta))
               (card-name               (orgtrello-data/entity-name        card-meta))
               (card-due                (orgtrello-data/entity-due         card-meta))
               (card-desc               (orgtrello-data/entity-description card-meta))
               (card-user-ids-assigned  (orgtrello-data/entity-member-ids  card-meta))
               (card-labels             (orgtrello-proxy/--tags-to-labels (orgtrello-data/entity-tags card-meta))))
          (if card-id
              ;; update
              (orgtrello-api/move-card card-id list-id card-name card-due card-user-ids-assigned card-desc card-labels)
            ;; create
            (orgtrello-api/add-card card-name list-id card-due card-user-ids-assigned card-desc card-labels)))
      checks-ok-or-error-message)))

(defun orgtrello-proxy/--checks-before-sync-checklist (checklist-meta card-meta)
  "Check all is good before synchronizing the CHECKLIST-META (CARD-META indispensable)."
  (-if-let (checklist-name (orgtrello-data/entity-name checklist-meta))
      (-if-let (card-id (orgtrello-data/entity-id card-meta))
          :ok
        *ORGTRELLO/ERROR-SYNC-CHECKLIST-SYNC-CARD-FIRST*)
    *ORGTRELLO/ERROR-SYNC-CHECKLIST-MISSING-NAME*))

(defun orgtrello-proxy/--checklist (checklist-meta &optional card-meta grandparent-meta)
  "Deal with create/update CHECKLIST-META query build.
CARD-META, GRANDPARENT-META are indispensable.
If the checks are ko, the error message is returned."
  (let ((checks-ok-or-error-message (orgtrello-proxy/--checks-before-sync-checklist checklist-meta card-meta)))
    ;; name is mandatory
    (if (equal :ok checks-ok-or-error-message)
        ;; grandparent is useless here
        (let ((card-id        (orgtrello-data/entity-id card-meta))
              (checklist-name (orgtrello-data/entity-name checklist-meta)))
          (-if-let (checklist-id (orgtrello-data/entity-id checklist-meta))
              ;; update
              (orgtrello-api/update-checklist checklist-id checklist-name)
            ;; create
            (orgtrello-api/add-checklist card-id checklist-name)))
      checks-ok-or-error-message)))

(defun orgtrello-proxy/--compute-state (state)
  "Given a STATE (TODO/DONE) compute the trello state equivalent."
  (orgtrello-data/--compute-state-generic state '("complete" "incomplete")))

(defun orgtrello-proxy/--compute-check (state)
  "Given a STATE (TODO/DONE) compute the trello check equivalent."
  (orgtrello-data/--compute-state-generic state '(t nil)))

(defun orgtrello-proxy/--checks-before-sync-item (item-meta checklist-meta card-meta)
  "Check all is good before synchronizing the item ITEM-META (CHECKLIST-META and CARD-META indispensable)."
  (let ((item-name    (orgtrello-data/entity-name item-meta))
        (checklist-id (orgtrello-data/entity-id checklist-meta))
        (card-id      (orgtrello-data/entity-id card-meta)))
    (if item-name
        (if checklist-id
            (if card-id :ok *ORGTRELLO/ERROR-SYNC-ITEM-SYNC-CARD-FIRST*)
          *ORGTRELLO/ERROR-SYNC-ITEM-SYNC-CHECKLIST-FIRST*)
      *ORGTRELLO/ERROR-SYNC-ITEM-MISSING-NAME*)))

(defun orgtrello-proxy/--item (item-meta &optional checklist-meta card-meta)
  "Deal with create/update ITEM-META query build.
CHECKLIST-META and CARD-META are indispensable data to compute the query.
If the checks are ko, the error message is returned."
  (let ((checks-ok-or-error-message (orgtrello-proxy/--checks-before-sync-item item-meta checklist-meta card-meta)))
    ;; name is mandatory
    (if (equal :ok checks-ok-or-error-message)
        ;; card-meta is only usefull for the update part
        (let* ((item-id         (orgtrello-data/entity-id item-meta))
               (checklist-id    (orgtrello-data/entity-id checklist-meta))
               (card-id         (orgtrello-data/entity-id card-meta))
               (item-name       (orgtrello-data/entity-name item-meta))
               (item-state      (orgtrello-data/entity-keyword item-meta)))
          ;; update/create items
          (if item-id
              ;; update - rename, check or uncheck the item
              (orgtrello-api/update-item card-id
                                         checklist-id
                                         item-id
                                         item-name
                                         (orgtrello-proxy/--compute-state item-state))
            ;; create
            (orgtrello-api/add-items checklist-id
                                     item-name
                                     (orgtrello-proxy/--compute-check item-state))))
      checks-ok-or-error-message)))

(defvar *MAP-DISPATCH-CREATE-UPDATE* (orgtrello-hash/make-properties `((,*ORGTRELLO/CARD-LEVEL*      . orgtrello-proxy/--card)
                                                                       (,*ORGTRELLO/CHECKLIST-LEVEL* . orgtrello-proxy/--checklist)
                                                                       (,*ORGTRELLO/ITEM-LEVEL*      . orgtrello-proxy/--item)))
  "Dispatch map for the creation/update of card/checklist/item.")

(defun orgtrello-proxy/--dispatch-create (entry-metadata)
  "Dispatch the ENTRY-METADATA creation depending on the nature of the entry."
  (let ((current-meta        (orgtrello-data/current entry-metadata)))
    (-> current-meta
      orgtrello-data/entity-level
      (gethash *MAP-DISPATCH-CREATE-UPDATE* 'orgtrello-action/--too-deep-level)
      (funcall current-meta (orgtrello-data/parent entry-metadata) (orgtrello-data/grandparent entry-metadata)))))

(defun orgtrello-proxy/--sync-entity (entity-data entity-full-metadata)
  "Execute the entity ENTITY-DATA and ENTITY-FULL-METADATA synchronization."
  (lexical-let ((query-map           (orgtrello-proxy/--dispatch-create entity-full-metadata))
                (entity-full-meta    entity-full-metadata)
                (level               (orgtrello-data/entity-level entity-data)))
    (if (hash-table-p query-map)
        (orgtrello-query/http-trello
         query-map
         'synchronous-query
         (orgtrello-proxy/--standard-post-or-put-success-callback entity-data)
         (function* (lambda (&key error-thrown &allow-other-keys)
                      (orgtrello-log/msg *OT/ERROR* "client - Problem during the sync request to the proxy- error-thrown: %s" error-thrown)
                      (orgtrello-proxy/--cleanup-meta entity-full-meta)
                      (throw 'org-trello-timer-go-to-sleep t))))
      ;; cannot execute the request
      (progn
        (orgtrello-log/msg *OT/INFO* query-map)
        (orgtrello-proxy/--cleanup-meta entity-full-metadata)
        (throw 'org-trello-timer-go-to-sleep t)))))

(defun orgtrello-proxy/--deal-with-entity-action (entity-data)
  "Compute the synchronization of an entity ENTITY-DATA (retrieving latest information from buffer)."
  (let* ((position    (orgtrello-data/entity-position entity-data))   ;; position is mandatory
         (buffer-name (orgtrello-data/entity-buffername entity-data))    ;; buffer-name too
         (marker      (orgtrello-data/entity-id-or-marker entity-data))  ;; retrieve the id (which serves as a marker too)
         (level       (orgtrello-data/entity-level entity-data)))
    (orgtrello-log/msg *OT/TRACE* "Proxy-consumer - Searching entity metadata from buffer '%s' at point '%s' to sync..." buffer-name position)
    (orgtrello-action/--safe-wrap-or-throw-error ;; will update via tag the trello id of the new persisted data (if needed)
     (with-silent-modifications
       (with-current-buffer buffer-name
         (when (orgtrello-proxy/--get-back-to-marker marker entity-data)
           (-> entity-data
             orgtrello-data/entity-action
             orgtrello-proxy/--dispatch-action
             (funcall entity-data (orgtrello-buffer/entry-get-full-metadata!)))))))))

(defun orgtrello-proxy/--delete-region (start end)
  "Delete a region defined by START and END bound."
  (remove-overlays start end) ;; remove overlays on the card region
  (delete-region start end))

(defun orgtrello-proxy/--delete-card-region ()
  "Delete the card region (including overlays and line)."
  (org-back-to-heading)
  (let ((starting-point (point))
        (ending-point   (save-excursion (if (org-goto-sibling) (point) (point-max))))) ;; next card or point-max
    (orgtrello-proxy/--delete-region starting-point ending-point)))

(defun orgtrello-proxy/--delete-checkbox-checklist-region ()
  "Delete the checklist region."
  (let ((starting-point (point-at-bol))
        (ending-point (save-excursion (-if-let (result (orgtrello-cbx/--goto-next-checkbox-with-same-level! *ORGTRELLO/CHECKLIST-LEVEL*))
                                          result
                                        (orgtrello-cbx/compute-next-card-point!))))) ;; next checkbox or next card or point-max
    (orgtrello-proxy/--delete-region starting-point ending-point)))

(defun orgtrello-proxy/--delete-checkbox-item-region ()
  "Delete the item region."
  (let ((starting-point (point-at-bol))
        (ending-point (1+ (point-at-eol))))
    (orgtrello-proxy/--delete-region starting-point ending-point)))

(defun orgtrello-proxy/delete-region (entity)
  "Compute the delete region function depending on the ENTITY's nature."
  (cond ((orgtrello-data/entity-card-p entity) 'orgtrello-proxy/--delete-card-region)
        ((orgtrello-data/entity-checklist-p entity) 'orgtrello-proxy/--delete-checkbox-checklist-region)
        ((orgtrello-data/entity-item-p entity) 'orgtrello-proxy/--delete-checkbox-item-region)))

(defun orgtrello-proxy/--standard-delete-success-callback (entity-to-del)
  "Return a callback function able to deal with the ENTITY-TO-DEL deletion."
  (lexical-let ((entry-position    (orgtrello-data/entity-position entity-to-del))
                (entry-buffer-name (orgtrello-data/entity-buffername entity-to-del))
                (entry-level       (orgtrello-data/entity-level entity-to-del))
                (marker            (orgtrello-data/entity-id entity-to-del))
                (level             (orgtrello-data/entity-level entity-to-del)))
    (lambda (&rest response)
      (orgtrello-action/safe-wrap
       (with-current-buffer entry-buffer-name
         (save-excursion
           (when (orgtrello-proxy/--getting-back-to-marker marker)
             (-> (orgtrello-buffer/entry-get-full-metadata!)
               orgtrello-data/current
               orgtrello-proxy/delete-region
               funcall))))
       (orgtrello-proxy/--cleanup-and-save-buffer-metadata level entry-buffer-name)))))

(defun orgtrello-proxy/--card-delete (card-meta &optional parent-meta)
  "Deal with the deletion query of a CARD-META.
PARENT-META is not used here."
  (orgtrello-api/delete-card (orgtrello-data/entity-id card-meta)))

(defun orgtrello-proxy/--checklist-delete (checklist-meta &optional parent-meta)
  "Deal with the deletion query of a CHECKLIST-META.
PARENT-META is not used here."
  (orgtrello-api/delete-checklist (orgtrello-data/entity-id checklist-meta)))

(defun orgtrello-proxy/--item-delete (item-meta &optional checklist-meta)
  "Deal with create/update query of an ITEM-META in CHECKLIST-META."
  (orgtrello-api/delete-item (orgtrello-data/entity-id checklist-meta) (orgtrello-data/entity-id item-meta)))

(defvar *MAP-DISPATCH-DELETE* (orgtrello-hash/make-properties `((,*ORGTRELLO/CARD-LEVEL*      . orgtrello-proxy/--card-delete)
                                                                (,*ORGTRELLO/CHECKLIST-LEVEL* . orgtrello-proxy/--checklist-delete)
                                                                (,*ORGTRELLO/ITEM-LEVEL*      . orgtrello-proxy/--item-delete)))
  "Dispatch map for the deletion query of card/checklist/item.")

(defun orgtrello-proxy/--dispatch-delete (meta &optional parent-meta)
  "Dispatch the call to the delete function depending on META level info.
Optionally, PARENT-META is a parameter of the function dispatched."
  (-> meta
    orgtrello-data/entity-level
    (gethash *MAP-DISPATCH-DELETE* 'orgtrello-action/--too-deep-level)
    (funcall meta parent-meta)))

(defun orgtrello-proxy/--delete (entity-data entity-full-metadata)
  "Execute the delete query to remove ENTITY-DATA and ENTITY-FULL-METADATA."
  (lexical-let ((query-map        (orgtrello-proxy/--dispatch-delete (orgtrello-data/current entity-full-metadata) (orgtrello-data/parent entity-full-metadata)))
                (entity-full-meta entity-full-metadata)
                (level            (orgtrello-data/entity-level entity-data)))
    (if (hash-table-p query-map)
        (orgtrello-query/http-trello
         query-map
         nil ;; asynchronous-query
         (orgtrello-proxy/--standard-delete-success-callback entity-data)
         (function* (lambda (&key error-thrown &allow-other-keys)
                      (orgtrello-log/msg *OT/ERROR* "client - Problem during the deletion request to the proxy- error-thrown: %s" error-thrown)
                      (orgtrello-proxy/--cleanup-meta entity-full-meta)
                      (throw 'org-trello-timer-go-to-sleep t))))
      (progn
        (orgtrello-log/msg *OT/INFO* query-map)
        (throw 'org-trello-timer-go-to-sleep t)))))

(orgtrello-log/msg *OT/DEBUG* "org-trello - orgtrello-proxy loaded!")

(provide 'org-trello-proxy)
;;; org-trello-proxy.el ends here